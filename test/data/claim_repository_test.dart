// test/data/claim_repository_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/models/logical_clock.dart';

Uint8List _sig(int fill) => Uint8List.fromList(List<int>.filled(64, fill));

Claim _claim({
  required String id,
  required ClaimType type,
  required ClaimPayload payload,
  String originDeviceId = 'device-a',
  int originSequence = 1,
  int clockCounter = 1,
  ClaimStatus status = ClaimStatus.active,
  Duration? displayLifetime,
}) {
  return Claim(
    id: id,
    type: type,
    originDeviceId: originDeviceId,
    originSequence: originSequence,
    originSignature: _sig(0xAB),
    logicalClock: LogicalClock(deviceId: originDeviceId, counter: clockCounter),
    claimTrust: ClaimTrust.unconfirmed,
    dispatchPriority: DispatchPriority.low,
    status: status,
    hopLimit: 10,
    displayLifetime: displayLifetime,
    createdAtLogical:
        LogicalClock(deviceId: originDeviceId, counter: clockCounter),
    payload: payload,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late ClaimRepository repo;

  setUp(() async {
    await DatabaseHelper.instance.resetForTest();
    repo = ClaimRepository();
  });

  test('insert then read back returns an equivalent claim', () async {
    final original = _claim(
      id: 'sos-abc',
      type: ClaimType.sos,
      originSequence: 7,
      clockCounter: 3,
      payload: const SosPayload(
        location: GeoPoint(lat: 12.9716, lon: 77.5946),
        headcount: HeadcountBucket.sixToFifteen,
      ),
    );

    await repo.insertClaim(original);
    final read = await repo.getClaim('sos-abc');

    expect(read, isNotNull);
    expect(read!.id, original.id);
    expect(read.type, original.type);
    expect(read.originDeviceId, original.originDeviceId);
    expect(read.claimTrust, original.claimTrust);
    expect(read.dispatchPriority, original.dispatchPriority);
    expect(read.status, original.status);
    expect(read.hopLimit, original.hopLimit);
    expect(read.logicalClock.deviceId, original.logicalClock.deviceId);
    expect(read.logicalClock.counter, original.logicalClock.counter);
    expect(read.createdAtLogical!.counter, original.createdAtLogical!.counter);

    // The two counters are stored separately and must come back distinct —
    // this is the regression guard for them ever being aliased again (§2/§4).
    expect(read.originSequence, 7);
    expect(read.logicalClock.counter, 3);

    // Signature survives as raw bytes, not mangled through a String.
    expect(read.originSignature, equals(original.originSignature));
    expect(read.originSignature.length, 64);

    final payload = read.payload as SosPayload;
    expect(payload.location.lat, closeTo(12.9716, 0.001));
    expect(payload.location.lon, closeTo(77.5946, 0.001));
    expect(payload.headcount, HeadcountBucket.sixToFifteen);
  });

  test('a signature containing bytes no String would survive round-trips',
      () async {
    // 0x00 and high bytes are exactly what broke when signatures were held
    // as a Dart String (UTF-16) instead of bytes.
    final hostile = Uint8List.fromList(
      List<int>.generate(64, (i) => (i * 7) % 256),
    );
    final claim = Claim(
      id: 'sig-test',
      type: ClaimType.hazardReport,
      originDeviceId: 'device-a',
      originSequence: 1,
      originSignature: hostile,
      logicalClock: const LogicalClock(deviceId: 'device-a', counter: 1),
      claimTrust: ClaimTrust.unconfirmed,
      dispatchPriority: DispatchPriority.low,
      status: ClaimStatus.active,
      hopLimit: 10,
      displayLifetime: const Duration(hours: 48),
      createdAtLogical: const LogicalClock(deviceId: 'device-a', counter: 1),
      payload: const HazardReportPayload(
        location: GeoPoint(lat: 1, lon: 2),
        hazardType: HazardType.flood,
        confirmationCount: 1,
      ),
    );

    await repo.insertClaim(claim);
    final read = await repo.getClaim('sig-test');
    expect(read!.originSignature, equals(hostile));
  });

  test('two SOS in the same geohash bucket persist as two rows (§2.1)',
      () async {
    const sameLocation = GeoPoint(lat: 12.9716, lon: 77.5946);

    await repo.insertClaim(_claim(
      id: 'sos-family-one',
      type: ClaimType.sos,
      originDeviceId: 'device-a',
      payload: const SosPayload(location: sameLocation),
    ));
    await repo.insertClaim(_claim(
      id: 'sos-family-two',
      type: ClaimType.sos,
      originDeviceId: 'device-b',
      payload: const SosPayload(location: sameLocation),
    ));

    final active = await repo.getActiveClaims();
    expect(active.length, 2);
    expect(
      active.map((c) => c.id).toSet(),
      {'sos-family-one', 'sos-family-two'},
    );

    // Same bucket, as the merge rule would have computed — but SOS never
    // merges, so both rows survive independently.
    final buckets = active.map((c) => c.payload.location.lat).toSet();
    expect(buckets.length, 1);
  });

  test('updateClaim persists a status change without creating a row',
      () async {
    final claim = _claim(
      id: 'sos-update',
      type: ClaimType.sos,
      payload: const SosPayload(location: GeoPoint(lat: 5, lon: 5)),
    );
    await repo.insertClaim(claim);

    claim.status = ClaimStatus.resolved;
    claim.resolutionMethod = ResolutionMethod.qr;
    claim.resolvedByVolunteerId = 'volunteer-1';
    claim.resolvedAtLogical =
        const LogicalClock(deviceId: 'volunteer-1', counter: 9);
    await repo.updateClaim(claim);

    final read = await repo.getClaim('sos-update');
    expect(read!.status, ClaimStatus.resolved);
    expect(read.resolutionMethod, ResolutionMethod.qr);
    expect(read.resolvedByVolunteerId, 'volunteer-1');
    expect(read.resolvedAtLogical!.counter, 9);

    // Resolved claims are no longer active.
    expect(await repo.getActiveClaims(), isEmpty);
  });

  test('displayLifetime is null for SOS and preserved for hazard (§2.3)',
      () async {
    await repo.insertClaim(_claim(
      id: 'sos-no-decay',
      type: ClaimType.sos,
      payload: const SosPayload(location: GeoPoint(lat: 1, lon: 1)),
    ));
    await repo.insertClaim(_claim(
      id: 'hazard-decays',
      type: ClaimType.hazardReport,
      displayLifetime: const Duration(hours: 48),
      payload: const HazardReportPayload(
        location: GeoPoint(lat: 1, lon: 1),
        hazardType: HazardType.flood,
        confirmationCount: 1,
      ),
    ));

    expect((await repo.getClaim('sos-no-decay'))!.displayLifetime, isNull);
    expect(
      (await repo.getClaim('hazard-decays'))!.displayLifetime,
      const Duration(hours: 48),
    );
  });

  group('an unsigned claim never reaches the store (§5)', () {
    Claim unsignedClaim(Uint8List signature) => Claim(
          id: 'unsigned-claim',
          type: ClaimType.hazardReport,
          originDeviceId: 'device-a',
          originSequence: 1,
          originSignature: signature,
          logicalClock: const LogicalClock(deviceId: 'device-a', counter: 1),
          claimTrust: ClaimTrust.unconfirmed,
          dispatchPriority: DispatchPriority.low,
          status: ClaimStatus.active,
          hopLimit: 10,
          displayLifetime: const Duration(hours: 48),
          createdAtLogical:
              const LogicalClock(deviceId: 'device-a', counter: 1),
          payload: const HazardReportPayload(
            location: GeoPoint(lat: 1, lon: 2),
            hazardType: HazardType.flood,
            confirmationCount: 1,
          ),
        );

    test('insertClaim refuses the empty ClaimFactory placeholder', () async {
      // The exact local-path mistake: build a claim, skip signing, store it.
      // Before this guard the row landed and rendered like any other.
      await expectLater(
        repo.insertClaim(unsignedClaim(Uint8List(0))),
        throwsA(isA<UnsignedClaimException>()),
      );
      expect(await repo.getClaim('unsigned-claim'), isNull);
    });

    test('insertClaim refuses a truncated signature', () async {
      // 63 bytes is not "nearly signed". Ed25519 signatures are exactly 64,
      // so anything else is malformed rather than merely unlucky.
      await expectLater(
        repo.insertClaim(unsignedClaim(Uint8List(63))),
        throwsA(isA<UnsignedClaimException>()),
      );
      expect(await repo.getClaim('unsigned-claim'), isNull);
    });

    test('updateClaim cannot strip the signature off a stored claim',
        () async {
      // The write path is not only insert. A claim that entered the store
      // signed must not be able to leave a later update unsigned.
      final signed = unsignedClaim(_sig(0xAB));
      await repo.insertClaim(signed);

      signed.originSignature = Uint8List(0);
      await expectLater(
        repo.updateClaim(signed),
        throwsA(isA<UnsignedClaimException>()),
      );

      final held = await repo.getClaim('unsigned-claim');
      expect(held!.originSignature.length, 64);
    });

    test('a properly signed claim still stores', () async {
      // The guard must reject the unsigned case without narrowing the honest
      // one — including signatures full of 0x00 bytes, which are valid.
      await repo.insertClaim(unsignedClaim(_sig(0x00)));
      expect(await repo.getClaim('unsigned-claim'), isNotNull);
    });
  });
}
