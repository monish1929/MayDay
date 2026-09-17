// test/mesh/mesh_node_test.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/time/device_clock.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/mesh/claim_ingestion.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/mesh/envelope_signer.dart';
import 'package:mayday/mesh/mesh_node.dart';
import 'package:mayday/mesh/mesh_transport.dart';
import 'package:mayday/mesh/relay_queue.dart';

const _here = GeoPoint(lat: 12.9716, lon: 77.5946);

/// A radio that never existed. Frames are handed in by the test; sends are
/// recorded instead of transmitted.
class _FakeTransport implements MeshTransport {
  final _controller = StreamController<InboundFrame>.broadcast();
  final List<({RelayTarget target, Uint8List bytes})> sent = [];

  @override
  List<RelayTarget> peers = const [RelayTarget(peerId: 'neighbour')];

  bool started = false;

  @override
  Stream<InboundFrame> get inbound => _controller.stream;

  @override
  Future<bool> send(RelayTarget target, Uint8List bytes) async {
    sent.add((target: target, bytes: bytes));
    return true;
  }

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async {
    started = false;
    await _controller.close();
  }

  /// Simulates a neighbour writing to our characteristic.
  void deliver(Uint8List bytes) {
    _controller.add(InboundFrame(
      from: const RelayTarget(peerId: 'neighbour'),
      bytes: bytes,
    ));
  }
}

/// Flips one bit in the body, leaving the signature untouched.
Envelope _tamper(Envelope e) {
  final body = Uint8List.fromList(e.body);
  body[body.length ~/ 2] ^= 0xff;
  return Envelope(
    v: e.v,
    msgId: e.msgId,
    hopLimit: e.hopLimit,
    kind: e.kind,
    body: body,
    originPubKey: e.originPubKey,
    originSig: e.originSig,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late _FakeTransport transport;
  late ClaimRepository repository;
  late MeshNode node;
  late DeviceKeyPair self;
  late DeviceKeyPair stranger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    transport = _FakeTransport();
    repository = ClaimRepository();
    self = await DeviceKeyPair.generate();
    stranger = await DeviceKeyPair.generate();
    node = MeshNode(
      transport: transport,
      keyPair: self,
      ingestion: ClaimIngestion(
        repository: repository,
        deviceClock: const DeviceClock('this-device'),
      ),
    );
    await node.start();
  });

  tearDown(() async {
    await node.stop();
  });

  /// Lets delivered frames reach the node and finish processing.
  ///
  /// A broadcast stream hands the frame over asynchronously and the node then
  /// chains the work, so pumping alone can return before the store write has
  /// landed. Pump, then await the node's own chain.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
      await node.idle;
    }
  }

  // NOTE ON SCOPE: `data/` reaches DatabaseHelper.instance directly, so one
  // test process has exactly one store. That store stands for the RECEIVING
  // device here, which works because MeshNode.originate deliberately does not
  // write to it — origination is the transmit path, and `data/` stores a
  // locally raised claim separately. Two genuinely separate stores is what the
  // two-phone run in PERSON_A.md Week 2 Day 4 is for; this proves the wiring,
  // not the hardware.

  /// Builds a claim as some other device would and signs it for the wire.
  Future<Envelope> fromStranger({
    ClaimPayload? payload,
    DeviceKeyPair? by,
    String? claimDeviceId,
    int hopLimit = 5,
  }) async {
    final keyPair = by ?? stranger;
    final claim = await ClaimFactory.createClaim(
      payload: payload ?? const SosPayload(location: _here),
      originDeviceId: claimDeviceId ?? keyPair.deviceId,
    );
    return EnvelopeSigner.sign(
      kind: EnvelopeKind.claim,
      body: Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
      keyPair: keyPair,
      hopLimit: hopLimit,
    );
  }

  group('a claim crosses the wire into the store', () {
    test('an SOS from a neighbour is stored, intact and verified', () async {
      final envelope = await fromStranger();
      transport.deliver(envelope.encode());
      await settle();

      expect(node.stats.stored, 1);
      final claims = await repository.getActiveClaims();
      expect(claims.length, 1);
      expect(claims.single.type, ClaimType.sos);
      expect(claims.single.originDeviceId, stranger.deviceId);
      expect(claims.single.originSignature, envelope.originSig);
    });

    test('and is forwarded onward', () async {
      transport.deliver((await fromStranger()).encode());
      await settle();
      await node.flush();

      expect(transport.sent.length, 1);
      final relayed = Envelope.decode(transport.sent.single.bytes);
      expect(relayed, isA<EnvelopeDecodeOk>());
      // hopLimit spent one hop; msgId survives, or de-dup breaks downstream.
      expect((relayed as EnvelopeDecodeOk).envelope.hopLimit, 4);
    });
  });

  group('receiving is not corroborating', () {
    test('a relayed claim arrives UNCONFIRMED with no corroborations',
        () async {
      transport.deliver((await fromStranger()).encode());
      await settle();

      final stored = (await repository.getActiveClaims()).single;
      // CLAUDE.md §2.2. This device learned nothing by being handed a message
      // — it did not witness anything and no human attested to anything.
      expect(stored.claimTrust, ClaimTrust.unconfirmed);
      expect(stored.corroborations, isEmpty);
      expect(stored.dispatchPriority, DispatchPriority.low);
    });

    test('forwarding it does not move trust either', () async {
      transport.deliver((await fromStranger()).encode());
      await settle();
      await node.flush();

      final stored = (await repository.getActiveClaims()).single;
      expect(stored.claimTrust, ClaimTrust.unconfirmed);
      expect(stored.corroborations, isEmpty);
    });
  });

  group('two SOS in one geohash bucket stay two claims', () {
    // CLAUDE.md §6.2 calls this the single most important test in the repo.
    // Proven in B's harness already; proven here across the wire, because the
    // failure this guards against is two families on one street being merged
    // into one pin and one of them vanishing when the other is resolved.
    test('same bucket, different origin devices, two records', () async {
      final familyOne = await DeviceKeyPair.generate();
      final familyTwo = await DeviceKeyPair.generate();

      transport.deliver((await fromStranger(by: familyOne)).encode());
      transport.deliver((await fromStranger(by: familyTwo)).encode());
      await settle();

      final claims = await repository.getActiveClaims();
      expect(claims.length, 2);
      expect(claims.map((c) => c.id).toSet().length, 2);
      expect(
        claims.map((c) => c.originDeviceId).toSet(),
        {familyOne.deviceId, familyTwo.deviceId},
      );
    });
  });

  group('hostile and malformed input', () {
    test('random bytes are dropped without crashing', () async {
      transport.deliver(Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]));
      await settle();

      expect(node.stats.undecodable, 1);
      expect(node.stats.stored, 0);
      expect(await repository.getActiveClaims(), isEmpty);
    });

    test('a tampered body is not stored and not relayed', () async {
      transport.deliver(_tamper(await fromStranger()).encode());
      await settle();
      await node.flush();

      expect(node.stats.signatureInvalid, 1);
      expect(await repository.getActiveClaims(), isEmpty);
      expect(transport.sent, isEmpty);
    });

    test('a claim wearing a neighbour id is stored nowhere and relayed nowhere',
        () async {
      // Correctly signed by `stranger`, but naming `victim` as the origin.
      // For SOS this mints ids inside the victim's id space — resolving one
      // rescue could then clear a different person's (§2).
      final victim = await DeviceKeyPair.generate();
      final forged = await fromStranger(claimDeviceId: victim.deviceId);

      transport.deliver(forged.encode());
      await settle();
      await node.flush();

      expect(node.stats.ingestRejected, 1);
      expect(await repository.getActiveClaims(), isEmpty);
      // The point of the test: an honest device must not amplify this.
      expect(transport.sent, isEmpty);
    });
  });

  group('origination', () {
    test('an SOS is stamped with the SOS hop limit', () async {
      final claim = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: self.deviceId,
      );
      final envelope = await node.originate(claim);

      expect(envelope.hopLimit, node.policy.initialHopLimitFor(ClaimType.sos));
      await node.flush();
      expect(transport.sent.length, 1);
    });

    test('a resource claim gets less reach than an SOS', () async {
      final rice = await ClaimFactory.createClaim(
        payload: const ResourcePayload(
          location: _here,
          category: ResourceCategory.foodWater,
          pledgedCount: 5,
          claimedReports: 0,
        ),
        originDeviceId: self.deviceId,
      );
      final sos = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: self.deviceId,
      );

      expect(
        (await node.originate(rice)).hopLimit,
        lessThan((await node.originate(sos)).hopLimit),
      );
    });

    test('our own message flooded back to us is dropped, not re-stored',
        () async {
      final claim = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: self.deviceId,
      );
      final envelope = await node.originate(claim);

      // A neighbour relays it straight back — exactly what Phase 0 observed
      // on real hardware.
      transport.deliver(envelope.encode());
      await settle();

      expect(node.stats.duplicates, 1);
      expect(node.stats.stored, 0);
    });
  });
}
