// test/flows/sos_origination_test.dart
//
// PERSON_A.md Wk3 D1 — raising an SOS, and CLAUDE.md §6.2's first row:
//
//   "Two SOS in the same geohash bucket, same minute →
//    two distinct claims, two pins, independent resolution"
//
// §6.2 calls that "the single most important test in the repo — it's the bug
// that would have made the system lose people." It is asserted at the claim
// layer in test/data/claim_id_test.dart; what is asserted here is the thing
// that actually ships: that the *flow a person taps* produces two separate
// records, from one device and from two, for all three sub-types.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/identity/geohash_utils.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/time/device_clock.dart';
import 'package:mayday/flows/rescue/sos_origination.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/mesh/claim_ingestion.dart';
import 'package:mayday/mesh/mesh_node.dart';
import 'package:mayday/mesh/mesh_transport.dart';
import 'package:mayday/mesh/relay_queue.dart';

/// Two families on the same street. The geohash bucket is 150–300m, so these
/// land in the same one — which is the entire point.
const _street = GeoPoint(lat: 12.9716, lon: 77.5946);
const _sameStreet = GeoPoint(lat: 12.97162, lon: 77.59462);

class _FakeTransport implements MeshTransport {
  final _controller = StreamController<InboundFrame>.broadcast();
  final List<Uint8List> sent = [];

  @override
  List<RelayTarget> peers = const [RelayTarget(peerId: 'neighbour')];

  @override
  Stream<InboundFrame> get inbound => _controller.stream;

  @override
  Future<bool> send(RelayTarget target, Uint8List bytes) async {
    sent.add(bytes);
    return true;
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async => _controller.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late ClaimRepository repository;
  late _FakeTransport transport;
  late MeshNode node;
  late SosOrigination flow;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    repository = ClaimRepository();
    transport = _FakeTransport();
    node = MeshNode(
      transport: transport,
      keyPair: await DeviceKeyPair.generate(),
      ingestion: ClaimIngestion(
        repository: repository,
        deviceClock: const DeviceClock('this-device'),
      ),
    );
    flow = SosOrigination(node: node, repository: repository);
  });

  /// A second phone, with its own key and its own view of the same store.
  Future<SosOrigination> secondDevice() async {
    return SosOrigination(
      node: MeshNode(
        transport: _FakeTransport(),
        keyPair: await DeviceKeyPair.generate(),
        ingestion: ClaimIngestion(
          repository: repository,
          deviceClock: const DeviceClock('other-device'),
        ),
      ),
      repository: repository,
    );
  }

  group('THE test — two SOS in one bucket stay two people (§2.1, §6.2)', () {
    test('two devices, same street, same moment → two claims, two pins',
        () async {
      final familyA = flow;
      final familyB = await secondDevice();

      final a = await familyA.raiseIndividual(location: _street);
      final b = await familyB.raiseIndividual(location: _sameStreet);

      expect(a.raised, isTrue);
      expect(b.raised, isTrue);
      expect(a.claim!.id, isNot(b.claim!.id),
          reason: 'one shared id would show two families as one pin, count '
              'them as corroborating each other, and make resolving one '
              'erase the other');

      // Both really are in the same merge bucket — the test is worthless if
      // the coordinates drifted apart and stopped exercising the collision.
      expect(getGeohashBucket(_street), getGeohashBucket(_sameStreet));

      final active = await repository.getActiveClaims();
      expect(active.where((c) => c.type == ClaimType.sos), hasLength(2));
    });

    test('resolving one leaves the other untouched', () async {
      // The consequence that matters. Independent ids are only meaningful if
      // independent resolution follows from them.
      final a = await flow.raiseIndividual(location: _street);
      final b = await (await secondDevice())
          .raiseIndividual(location: _sameStreet);

      final first = a.claim!;
      first.status = ClaimStatus.resolved;
      first.resolutionMethod = ResolutionMethod.qr;
      await repository.updateClaim(first);

      final other = await repository.getClaim(b.claim!.id);
      expect(other!.status, ClaimStatus.active,
          reason: 'the second family is still trapped');
    });

    test('one device raising twice produces two claims, not one', () async {
      // The sequence number is what separates these. A device raising a
      // second SOS has not corrected the first — it may be a second person on
      // the same phone, or the same person after moving.
      final first = await flow.raiseIndividual(location: _street);
      final second = await flow.raiseIndividual(location: _street);

      expect(first.claim!.id, isNot(second.claim!.id));
      expect(second.claim!.originSequence,
          greaterThan(first.claim!.originSequence));
    });

    test('all three sub-types at one location stay three claims', () async {
      // Mirrors DebugSosTrigger.raiseSosSuite, which exists for exactly this
      // check on hardware.
      final individual = await flow.raiseIndividual(location: _street);
      final group = await flow.raiseGroup(
        location: _street,
        headcount: HeadcountBucket.sixToFifteen,
      );
      final proxy = await flow.raiseProxy(
        location: _street,
        reporterDeviceId: node.keyPair.deviceId,
      );

      final ids = {
        individual.claim!.id,
        group.claim!.id,
        proxy.claim!.id,
      };
      expect(ids, hasLength(3));
    });
  });

  group('the three sub-types are three payloads, not three code paths', () {
    test('an individual SOS carries only a location', () async {
      final result = await flow.raiseIndividual(location: _street);

      expect(result.claim!.type, ClaimType.sos);
      final payload = result.claim!.payload as SosPayload;
      expect(payload.headcount, isNull);
    });

    test('a group SOS carries a bucket, never a precise number', () async {
      // "6–15" is what a frightened person on a roof can actually tell you.
      // A precise count would be false precision that dispatch then acts on.
      final result = await flow.raiseGroup(
        location: _street,
        headcount: HeadcountBucket.sixToFifteen,
      );

      final payload = result.claim!.payload as SosPayload;
      expect(payload.headcount, HeadcountBucket.sixToFifteen);
      expect(result.claim!.type, ClaimType.sos);
    });

    test('a proxy SOS records who reported it', () async {
      // Losing track of who actually saw the person is losing the only
      // provenance the claim has — a proxy claim gets relayed onward by third
      // parties who never saw anybody.
      final result = await flow.raiseProxy(
        location: _street,
        reporterDeviceId: 'reporter-device',
        note: 'trapped on the roof',
      );

      expect(result.claim!.type, ClaimType.sosProxy);
      final payload = result.claim!.payload as SosProxyPayload;
      expect(payload.reporterDeviceId, 'reporter-device');
      expect(payload.proxyNote, 'trapped on the roof');
    });

    test('an over-long proxy note is truncated, never refused', () async {
      // §9.2 caps free text at 80 characters against the 400-byte envelope
      // budget. An SOS that fails to send because somebody typed too much is
      // not an acceptable failure mode.
      final result = await flow.raiseProxy(
        location: _street,
        reporterDeviceId: 'reporter-device',
        note: 'x' * 500,
      );

      expect(result.raised, isTrue);
      expect((result.claim!.payload as SosProxyPayload).proxyNote!.length, 80);
    });
  });

  group('what a raised SOS looks like afterwards', () {
    test('it never decays — displayLifetime is null (§2.3)', () async {
      // Null, not a large number. A person trapped alone is UNCONFIRMED
      // precisely because nobody is nearby to corroborate them, which is
      // exactly why their claim must not age out.
      final result = await flow.raiseIndividual(location: _street);

      expect(result.claim!.displayLifetime, isNull);
      expect(result.claim!.type, ClaimType.sos);
    });

    test('the stored copy is signed, and is what a receiver would build',
        () async {
      // originate() signs and queues but does not store; the local copy is
      // rebuilt from the signed bytes the way a receiving device builds its
      // own. Persisting the pre-signature object would put an unsigned claim
      // in the store, which §2.5 forbids and ClaimRepository throws on.
      final result = await flow.raiseIndividual(location: _street);

      expect(result.claim!.originSignature, hasLength(64));
      final reloaded = await repository.getClaim(result.claim!.id);
      expect(reloaded!.originSignature, result.claim!.originSignature);
    });

    test('raising starts UNCONFIRMED — origination is not evidence', () async {
      // §2.2: only independent generation or explicit human attestation moves
      // trust. Raising your own SOS is neither, however true it is.
      final result = await flow.raiseIndividual(location: _street);

      expect(result.claim!.claimTrust, ClaimTrust.unconfirmed);
    });

    test('it is queued for flood', () async {
      final result = await flow.raiseIndividual(location: _street);

      expect(result.envelope, isNotNull);
      expect(result.envelope!.kind.index, 0);
    });
  });
}
