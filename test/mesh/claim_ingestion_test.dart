// test/mesh/claim_ingestion_test.dart

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/time/device_clock.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/mesh/claim_ingestion.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/mesh/envelope_signer.dart';
import 'package:mayday/mesh/receive_pipeline.dart';
import 'package:mayday/mesh/seen_message_cache.dart';

const _here = GeoPoint(lat: 12.9716, lon: 77.5946);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late ClaimRepository repository;
  late ClaimIngestion ingestion;
  late DeviceKeyPair sender;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    repository = ClaimRepository();
    sender = await DeviceKeyPair.generate();
    ingestion = ClaimIngestion(
      repository: repository,
      deviceClock: const DeviceClock('receiving-device'),
    );
  });

  /// Builds a claim on the sender's side exactly as a real origination would,
  /// then wraps and signs it for the wire.
  Future<Envelope> originate({
    ClaimPayload? payload,
    DeviceKeyPair? by,
    int hopLimit = 5,
  }) async {
    final keyPair = by ?? sender;
    final claim = await ClaimFactory.createClaim(
      payload: payload ?? const SosPayload(location: _here),
      originDeviceId: keyPair.deviceId,
    );
    return EnvelopeSigner.sign(
      kind: EnvelopeKind.claim,
      body: Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
      keyPair: keyPair,
      hopLimit: hopLimit,
    );
  }

  group('a genuine claim survives the wire', () {
    test('an originated claim round-trips into the receiver store', () async {
      final envelope = await originate();
      final result = await ingestion.ingest(envelope);

      expect(result.accepted, isTrue);
      final stored = await repository.getClaim(result.stored!.id);
      expect(stored, isNotNull);
      expect(stored!.originDeviceId, sender.deviceId);
      expect(stored.type, ClaimType.sos);
      expect(stored.originSignature, envelope.originSig);

      final payload = stored.payload as SosPayload;
      expect(payload.location.lat, closeTo(_here.lat, 0.001));
    });

    test('trust and priority arrive at the receiver defaults, not the sender',
        () async {
      // §2.2 — a claim cannot assert its own trustworthiness on arrival.
      final result = await ingestion.ingest(await originate());

      expect(result.stored!.claimTrust, ClaimTrust.unconfirmed);
      expect(result.stored!.dispatchPriority, DispatchPriority.low);
      expect(result.stored!.corroborations, isEmpty,
          reason: 'receiving a relayed claim is not corroboration');
    });

    test('SOS keeps a null displayLifetime; hazard gets the local policy',
        () async {
      final sos = await ingestion.ingest(await originate());
      expect(sos.stored!.displayLifetime, isNull,
          reason: 'SOS never decays — §2.3');

      await DatabaseHelper.instance.resetForTest();
      final hazard = await ingestion.ingest(await originate(
        payload: const HazardReportPayload(
          location: _here,
          hazardType: HazardType.flood,
          confirmationCount: 1,
        ),
      ));
      expect(hazard.stored!.displayLifetime, isNotNull);
    });

    test('the receiver Lamport clock advances past what it heard', () async {
      final clock = const DeviceClock('receiving-device');
      final before = (await clock.peek()).counter;

      final result = await ingestion.ingest(await originate());

      final after = (await clock.peek()).counter;
      expect(after, greaterThan(before));
      expect(after, greaterThan(result.stored!.logicalClock.counter));
    });
  });

  group('forged claims are rejected before they reach the store', () {
    test('a claim naming another device is rejected', () async {
      final victim = await DeviceKeyPair.generate();

      // Correctly signed by the attacker, but the body names the victim.
      final claim = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: victim.deviceId,
      );
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
        keyPair: sender,
        hopLimit: 5,
      );

      // The signature itself is perfectly valid — only the id binding catches it.
      expect(await EnvelopeSigner.verify(envelope), isTrue);

      final result = await ingestion.ingest(envelope);
      expect(result.rejection, IngestRejection.deviceIdMismatch);
      expect(await repository.getActiveClaims(), isEmpty);
    });

    test('a claim with a forged id is rejected', () async {
      // Signed by its real owner, but the id was not computed under §2's rule
      // — it was lifted, so resolving it could clear a stranger's rescue.
      final honest = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: sender.deviceId,
      );
      final forged = Claim(
        id: 'an-id-from-somebody-elses-space',
        type: honest.type,
        originDeviceId: honest.originDeviceId,
        originSequence: honest.originSequence,
        originSignature: Uint8List(0),
        logicalClock: honest.logicalClock,
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 5,
        createdAtLogical: honest.createdAtLogical,
        payload: honest.payload,
      );

      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: Uint8List.fromList(cbor.encode(forged.toSignedCoreCbor())),
        keyPair: sender,
        hopLimit: 5,
      );

      expect(await EnvelopeSigner.verify(envelope), isTrue);
      final result = await ingestion.ingest(envelope);
      expect(result.rejection, IngestRejection.forgedClaimId);
      expect(await repository.getActiveClaims(), isEmpty);
    });

    test('a malformed body is rejected without throwing', () async {
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: Uint8List.fromList([0xFF, 0xFF, 0xFF]),
        keyPair: sender,
        hopLimit: 5,
      );

      final result = await ingestion.ingest(envelope);
      expect(result.rejection, IngestRejection.malformedBody);
    });

    test('a non-claim kind is not ingested as a claim', () async {
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.timeGossip,
        body: Uint8List.fromList([1, 2, 3]),
        keyPair: sender,
        hopLimit: 5,
      );

      expect((await ingestion.ingest(envelope)).rejection,
          IngestRejection.malformedBody);
    });
  });

  group('two phones, one geohash bucket — the test that matters most', () {
    test('two SOS from different devices at the same spot stay separate',
        () async {
      // §2.1 / §6.2: the bug this whole split exists to prevent. Two families
      // on one street must not collapse into a single pin, or resolving one
      // rescue clears the other from every device in the mesh.
      final phoneOne = await DeviceKeyPair.generate();
      final phoneTwo = await DeviceKeyPair.generate();

      final first = await ingestion.ingest(
        await originate(by: phoneOne, payload: const SosPayload(location: _here)),
      );
      final second = await ingestion.ingest(
        await originate(by: phoneTwo, payload: const SosPayload(location: _here)),
      );

      expect(first.accepted, isTrue);
      expect(second.accepted, isTrue);
      expect(first.stored!.id, isNot(equals(second.stored!.id)));

      final active = await repository.getActiveClaims();
      expect(active.length, 2, reason: 'two rows, two pins, two resolutions');
    });

    test('two hazards in the same bucket collide by design', () async {
      // The mirror case: mergeable types SHOULD share an id.
      final phoneOne = await DeviceKeyPair.generate();
      final phoneTwo = await DeviceKeyPair.generate();
      const hazard = HazardReportPayload(
        location: _here,
        hazardType: HazardType.flood,
        confirmationCount: 1,
      );

      final first =
          await ingestion.ingest(await originate(by: phoneOne, payload: hazard));
      final second =
          await ingestion.ingest(await originate(by: phoneTwo, payload: hazard));

      expect(first.accepted, isTrue);
      expect(second.accepted, isTrue, reason: 'a second author is evidence');
      expect(second.merge?.corroborated, isTrue);
      expect((await repository.getActiveClaims()).length, 1,
          reason: 'one hazard, not two - mergeable ids are meant to collide');

      final stored = (await repository.getActiveClaims()).single;
      expect(stored.corroborations.length, 1);
      expect(stored.corroborations.single.deviceId, phoneTwo.deviceId);
      expect(stored.corroborations.single.kind,
          CorroborationKind.independentGeneration);

      // ONE corroborator is not enough. corroboratedThreshold is 2.0 and
      // maxContributionPerDevice is 1.0, so CORROBORATED needs the author plus
      // TWO independent witnesses. Staying unconfirmed here is the correct
      // answer, not a missing feature.
      expect(stored.claimTrust, ClaimTrust.unconfirmed);
    });

    test('a third independent author reaches CORROBORATED', () async {
      final phoneOne = await DeviceKeyPair.generate();
      final phoneTwo = await DeviceKeyPair.generate();
      final phoneThree = await DeviceKeyPair.generate();
      const hazard = HazardReportPayload(
        location: _here,
        hazardType: HazardType.flood,
        confirmationCount: 1,
      );

      await ingestion.ingest(await originate(by: phoneOne, payload: hazard));
      await ingestion.ingest(await originate(by: phoneTwo, payload: hazard));
      await ingestion.ingest(await originate(by: phoneThree, payload: hazard));

      final stored = (await repository.getActiveClaims()).single;
      expect(stored.corroborations.length, 2);
      expect(stored.claimTrust, ClaimTrust.corroborated);
    });

    test('one author repeating itself never raises trust', () async {
      final phoneOne = await DeviceKeyPair.generate();
      final loud = await DeviceKeyPair.generate();
      const hazard = HazardReportPayload(
        location: _here,
        hazardType: HazardType.flood,
        confirmationCount: 1,
      );

      await ingestion.ingest(await originate(by: phoneOne, payload: hazard));
      // One device, saying it twenty times. Section 2.2 plus the
      // corroborations table's PRIMARY KEY (claim_id, device_id): one device
      // is one witness, however loudly it repeats itself.
      for (var i = 0; i < 20; i++) {
        await ingestion.ingest(await originate(by: loud, payload: hazard));
      }

      final stored = (await repository.getActiveClaims()).single;
      expect(stored.corroborations.length, 1);
      expect(stored.claimTrust, ClaimTrust.unconfirmed);
    });

    test('two SOS in one bucket never corroborate each other', () async {
      final phoneOne = await DeviceKeyPair.generate();
      final phoneTwo = await DeviceKeyPair.generate();

      final a = await ingestion.ingest(await originate(by: phoneOne));
      final b = await ingestion.ingest(await originate(by: phoneTwo));

      expect(a.accepted, isTrue);
      expect(b.accepted, isTrue);
      final active = await repository.getActiveClaims();
      expect(active.length, 2);
      for (final claim in active) {
        expect(claim.corroborations, isEmpty);
        expect(claim.claimTrust, ClaimTrust.unconfirmed);
      }
    });
  });

  group('end to end through the real pipeline', () {
    test('a signed claim travels pipeline → ingestion → store', () async {
      final spyRelayed = <Envelope>[];
      final pipeline = ReceivePipeline(
        seenCache: SeenMessageCache(),
        store: (envelope) async => ingestion.ingest(envelope),
        relay: (envelope) async => spyRelayed.add(envelope),
      );

      final envelope = await originate(hopLimit: 3);
      expect(await pipeline.receive(envelope), ReceiveOutcome.storedAndRelayed);

      expect((await repository.getActiveClaims()).length, 1);
      expect(spyRelayed.single.hopLimit, 2);

      // Delivered a second time by another neighbour: de-duped, so the store
      // is untouched and nothing is re-relayed.
      expect(await pipeline.receive(envelope), ReceiveOutcome.duplicate);
      expect((await repository.getActiveClaims()).length, 1);
      expect(spyRelayed.length, 1);
    });

    test('a tampered claim never reaches the store', () async {
      final pipeline = ReceivePipeline(
        seenCache: SeenMessageCache(),
        store: (envelope) async => ingestion.ingest(envelope),
        relay: (envelope) async {},
      );

      final envelope = await originate();
      final tampered = Uint8List.fromList(envelope.body);
      tampered[tampered.length - 1] ^= 0xFF;

      final outcome = await pipeline.receive(Envelope(
        v: envelope.v,
        msgId: envelope.msgId,
        hopLimit: envelope.hopLimit,
        kind: envelope.kind,
        body: tampered,
        originPubKey: envelope.originPubKey,
        originSig: envelope.originSig,
      ));

      expect(outcome, ReceiveOutcome.signatureInvalid);
      expect(await repository.getActiveClaims(), isEmpty);
    });
  });
}
