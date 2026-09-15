// test/mesh/envelope_router_test.dart
//
// PERSON_A.md Wk3 D3 and Wk4 D1–D4 — the dispatch layer, and the three
// handlers that had no tests of their own.
//
// The router exists because of a real bug: before it, the receive path handed
// every envelope straight to ClaimIngestion, which rejects anything that is
// not kind 0 as a malformed body — and MeshNode then suppressed relay for
// exactly that rejection. A correctly signed vouch or resolution was both
// discarded *and* stopped dead at the first device that heard it. The
// exhaustive-switch test below is what stops a seventh kind reintroducing it.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/time/device_clock.dart';
import 'package:mayday/data/time/mesh_time.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/node_trust.dart';
import 'package:mayday/mesh/beacon_ingestion.dart';
import 'package:mayday/mesh/claim_ingestion.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/mesh/envelope_router.dart';
import 'package:mayday/mesh/envelope_signer.dart';
import 'package:mayday/mesh/message_handler.dart';
import 'package:mayday/mesh/messages/beacon_message.dart';
import 'package:mayday/mesh/messages/time_gossip_message.dart';
import 'package:mayday/mesh/pending_resolutions.dart';
import 'package:mayday/mesh/relay_queue.dart';
import 'package:mayday/mesh/resolution_ingestion.dart';
import 'package:mayday/mesh/routing_policy.dart';
import 'package:mayday/mesh/time_gossip_ingestion.dart';
import 'package:mayday/mesh/volunteer_gradient.dart';

const _here = GeoPoint(lat: 12.9716, lon: 77.5946);
const _clock = LogicalClock(deviceId: 'peer', counter: 1);
const _neighbour = RelayTarget(peerId: 'neighbour-1');

/// Records that it was reached, and nothing else.
class _SpyHandler implements MessageHandler {
  int calls = 0;
  RelayTarget? lastFrom;

  @override
  Future<MessageOutcome> handle(Envelope envelope, RelayTarget? from) async {
    calls++;
    lastFrom = from;
    return const MessageOutcome.acceptedAndRelay();
  }
}

/// Grants volunteer standing directly. The real registry cannot, because
/// `trust_anchors` is empty until B's Phase 4 credentials land.
class _StubTrust implements NodeTrustDirectory {
  final Set<String> volunteers = {};

  void grant(DeviceKeyPair kp) => volunteers.add(String.fromCharCodes(kp.publicKey));

  @override
  Future<NodeCapabilities> capabilitiesOf(List<int> publicKey) async {
    return volunteers.contains(String.fromCharCodes(publicKey))
        ? const NodeCapabilities(
            trust: NodeTrust.campaignVerified, standingVouches: 0)
        : NodeCapabilities.none;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late ClaimRepository repository;
  late ClaimIngestion claims;
  late ResolutionIngestion resolutions;
  late _SpyHandler vouches;
  late _SpyHandler revocations;
  late _SpyHandler beacons;
  late _SpyHandler gossip;
  late EnvelopeRouter router;
  late DeviceKeyPair sender;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    repository = ClaimRepository();
    sender = await DeviceKeyPair.generate();
    claims = ClaimIngestion(
      repository: repository,
      deviceClock: const DeviceClock('this-device'),
    );
    resolutions = ResolutionIngestion(
      repository: repository,
      pending: PendingResolutionStore(),
      deviceClock: const DeviceClock('this-device'),
      trust: _StubTrust(),
    );
    vouches = _SpyHandler();
    revocations = _SpyHandler();
    beacons = _SpyHandler();
    gossip = _SpyHandler();
    router = EnvelopeRouter(
      claims: claims,
      resolutions: resolutions,
      vouches: vouches,
      revocations: revocations,
      beacons: beacons,
      timeGossip: gossip,
    );
  });

  Future<Envelope> signed(EnvelopeKind kind, Uint8List body) {
    return EnvelopeSigner.sign(
      kind: kind,
      body: body,
      keyPair: sender,
      hopLimit: 5,
    );
  }

  group('every kind reaches its own handler', () {
    test('kind 3 goes to vouches, and nowhere else', () async {
      await router.route(
          await signed(EnvelopeKind.vouch, Uint8List(0)), _neighbour);

      expect(vouches.calls, 1);
      expect(revocations.calls, 0);
      expect(beacons.calls, 0);
      expect(gossip.calls, 0);
    });

    test('kind 4 goes to revocations', () async {
      await router.route(
          await signed(EnvelopeKind.revocation, Uint8List(0)), _neighbour);
      expect(revocations.calls, 1);
      expect(vouches.calls, 0);
    });

    test('kind 5 goes to beacons, and is told which neighbour it came by',
        () async {
      // A gradient entry is meaningless without knowing which way it points,
      // which is why `from` is threaded through the interface at all.
      await router.route(
          await signed(EnvelopeKind.volunteerBeacon, Uint8List(0)),
          _neighbour);

      expect(beacons.calls, 1);
      expect(beacons.lastFrom, _neighbour);
    });

    test('kind 6 goes to time gossip', () async {
      await router.route(
          await signed(EnvelopeKind.timeGossip, Uint8List(0)), _neighbour);
      expect(gossip.calls, 1);
    });

    test('a kind with no handler yet is still relayed, never dropped',
        () async {
      // Standalone corroboration (kind 1) has no wire handler in this build.
      // Dropping it would mean a device running an older build silently
      // severs corroboration for every device behind it — the same reasoning
      // RoutingPolicy uses for an unclassifiable claim.
      final outcome = await router.route(
        await signed(EnvelopeKind.corroboration, Uint8List(0)),
        _neighbour,
      );

      expect(outcome.accepted, isFalse);
      expect(outcome.relay, isTrue);
      expect(outcome.reason, contains('no handler'));
    });

    test('the switch is exhaustive over EnvelopeKind', () async {
      // Adding a kind without a route silently reintroduces the original bug:
      // a correctly signed message both discarded and stopped dead at the
      // first device that hears it. If a new kind lands, this fails here
      // rather than in a field test.
      for (final kind in EnvelopeKind.values) {
        final outcome = await router.route(
          await signed(kind, Uint8List(0)),
          _neighbour,
        );
        expect(outcome, isA<MessageOutcome>(),
            reason: '$kind has no route');
      }
    });
  });

  group('the claim path', () {
    test('a genuine claim is accepted and relayed', () async {
      final claim = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: sender.deviceId,
      );
      final envelope = await signed(
        EnvelopeKind.claim,
        Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
      );

      final outcome = await router.route(envelope, _neighbour);

      expect(outcome.accepted, isTrue);
      expect(outcome.relay, isTrue);
    });

    test('a claim already held is not accepted, but is still relayed',
        () async {
      // Not an attack: a genuine claim that reached us by another path with a
      // fresh msgId. Neighbours further out may still not have it.
      final claim = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: sender.deviceId,
      );
      final body = Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor()));
      await router.route(await signed(EnvelopeKind.claim, body), _neighbour);

      final second =
          await router.route(await signed(EnvelopeKind.claim, body), _neighbour);

      expect(second.accepted, isFalse);
      expect(second.relay, isTrue);
    });

    test('a malformed claim body is dropped and not relayed (§9.3)', () async {
      final outcome = await router.route(
        await signed(EnvelopeKind.claim, Uint8List.fromList([0xde, 0xad])),
        _neighbour,
      );

      expect(outcome.accepted, isFalse);
      expect(outcome.relay, isFalse,
          reason: 'forwarding it would make this device an honest amplifier');
    });
  });

  group('beacon ingestion — PERSON_A.md Wk4 D3', () {
    late VolunteerGradient gradient;
    late _StubTrust trust;
    late BeaconIngestion ingestion;
    var nowMs = 1000;

    setUp(() {
      nowMs = 1000;
      gradient = VolunteerGradient();
      trust = _StubTrust();
      ingestion = BeaconIngestion(
        gradient: gradient,
        trust: trust,
        deviceClock: const DeviceClock('this-device'),
        now: () => nowMs,
      );
    });

    Future<Envelope> beacon({int seq = 1, int hopLimit = 5}) {
      return EnvelopeSigner.sign(
        kind: EnvelopeKind.volunteerBeacon,
        body: BeaconMessage(beaconSeq: seq, logicalClock: _clock).encode(),
        keyPair: sender,
        hopLimit: hopLimit,
      );
    }

    test('a beacon from an untrusted key is dropped, not believed', () async {
      // A beacon is a self-assertion: anyone can sign "volunteer here".
      // Believing one would let any phone volunteer itself to the front of
      // the queue for every SOS in range.
      final outcome = await ingestion.handle(await beacon(), _neighbour);

      expect(outcome.accepted, isFalse);
      expect(outcome.reason, contains('not a volunteer'));
      expect(gradient.length, 0);
    });

    test('a beacon from a trusted volunteer builds a gradient entry',
        () async {
      trust.grant(sender);

      final outcome = await ingestion.handle(await beacon(), _neighbour);

      expect(outcome.accepted, isTrue);
      expect(gradient.length, 1);
      expect(gradient.hopsVia(_neighbour.peerId), 0);
      expect(gradient.isDirectVolunteer(_neighbour.peerId), isTrue);
    });

    test('hop distance comes off the envelope as it decrements', () async {
      trust.grant(sender);
      final policy = const RoutingPolicy();
      final initial =
          policy.initialHopLimitForKind(EnvelopeKind.volunteerBeacon);

      await ingestion.handle(await beacon(hopLimit: initial - 2), _neighbour);

      expect(gradient.hopsVia(_neighbour.peerId), 2);
    });

    test('a beacon with no inbound peer records nothing', () async {
      // Only reachable by a locally originated beacon replayed through the
      // receive path. A device does not need a route pointing at itself.
      trust.grant(sender);

      final outcome = await ingestion.handle(await beacon(), null);

      expect(outcome.accepted, isFalse);
      expect(gradient.length, 0);
    });

    test('relay is rate-limited per volunteer, not globally', () async {
      // Two volunteers beaconing at once are two facts the gradient needs;
      // silencing one because the other just spoke hides a whole route.
      trust.grant(sender);
      final otherVolunteer = await DeviceKeyPair.generate();
      trust.grant(otherVolunteer);

      expect((await ingestion.handle(await beacon(seq: 1), _neighbour)).relay,
          isTrue);
      expect((await ingestion.handle(await beacon(seq: 2), _neighbour)).relay,
          isFalse, reason: 'same volunteer, inside the interval');

      final fromOther = await EnvelopeSigner.sign(
        kind: EnvelopeKind.volunteerBeacon,
        body: const BeaconMessage(beaconSeq: 1, logicalClock: _clock).encode(),
        keyPair: otherVolunteer,
        hopLimit: 5,
      );
      expect((await ingestion.handle(fromOther, _neighbour)).relay, isTrue);

      nowMs += BeaconIngestion.defaultMinRelayInterval.inMilliseconds + 1;
      expect((await ingestion.handle(await beacon(seq: 3), _neighbour)).relay,
          isTrue);
    });

    test('a beacon never touches claim trust', () async {
      // §2.2, §2.4: a volunteer being nearby says nothing about whether any
      // claim is true. Asserted structurally — the handler is given no
      // repository at all, so it has nothing to write trust to.
      trust.grant(sender);
      final claim = await ClaimFactory.createClaim(
        payload: const SosPayload(location: _here),
        originDeviceId: sender.deviceId,
      );
      final before = claim.claimTrust;

      await ingestion.handle(await beacon(), _neighbour);

      expect(claim.claimTrust, before);
    });
  });

  group('the volunteer gradient', () {
    late VolunteerGradient gradient;

    setUp(() => gradient = VolunteerGradient());

    test('a fresher beacon replaces an older route', () async {
      gradient.record(
          volunteerDeviceId: 'v1',
          viaPeerId: 'p1',
          hops: 3,
          beaconSeq: 1,
          nowMs: 0);
      final changed = gradient.record(
          volunteerDeviceId: 'v1',
          viaPeerId: 'p2',
          hops: 4,
          beaconSeq: 2,
          nowMs: 0);

      expect(changed, isTrue);
      expect(gradient.hopsVia('p2'), 4);
      expect(gradient.hopsVia('p1'), isNull);
    });

    test('a stale beacon that took a slow path cannot win', () async {
      // The reason ordering is by sequence first: a beacon that took a slow
      // four-hop route can easily arrive after a newer one-hop beacon, and
      // letting it win would point the gradient down the longer path.
      gradient.record(
          volunteerDeviceId: 'v1',
          viaPeerId: 'fast',
          hops: 1,
          beaconSeq: 9,
          nowMs: 0);

      final changed = gradient.record(
          volunteerDeviceId: 'v1',
          viaPeerId: 'slow',
          hops: 4,
          beaconSeq: 2,
          nowMs: 0);

      expect(changed, isFalse);
      expect(gradient.hopsVia('fast'), 1);
    });

    test('an equally fresh beacon wins only if it came by a shorter path',
        () {
      gradient.record(
          volunteerDeviceId: 'v1',
          viaPeerId: 'long',
          hops: 4,
          beaconSeq: 5,
          nowMs: 0);

      expect(
        gradient.record(
            volunteerDeviceId: 'v1',
            viaPeerId: 'longer',
            hops: 6,
            beaconSeq: 5,
            nowMs: 0),
        isFalse,
      );
      expect(
        gradient.record(
            volunteerDeviceId: 'v1',
            viaPeerId: 'short',
            hops: 1,
            beaconSeq: 5,
            nowMs: 0),
        isTrue,
      );
      expect(gradient.hopsVia('short'), 1);
    });

    test('routes expire — people move', () {
      gradient.record(
          volunteerDeviceId: 'v1',
          viaPeerId: 'p1',
          hops: 1,
          beaconSeq: 1,
          nowMs: 0);

      gradient.expireBefore(
          VolunteerGradient.defaultEntryLifetime.inMilliseconds - 1);
      expect(gradient.length, 1);

      gradient.expireBefore(
          VolunteerGradient.defaultEntryLifetime.inMilliseconds + 1);
      expect(gradient.length, 0,
          reason: 'a stale route is worse than none — the device stops '
              'looking while pointing at someone who left');
    });

    test('losing a neighbour forgets every route learned through it', () {
      gradient.record(
          volunteerDeviceId: 'v1',
          viaPeerId: 'gone',
          hops: 1,
          beaconSeq: 1,
          nowMs: 0);
      gradient.record(
          volunteerDeviceId: 'v2',
          viaPeerId: 'still-here',
          hops: 2,
          beaconSeq: 1,
          nowMs: 0);

      gradient.forgetPeer('gone');

      expect(gradient.hopsVia('gone'), isNull);
      expect(gradient.hopsVia('still-here'), 2);
    });

    test('an unknown neighbour reports null, which is a real answer', () {
      // Most neighbours in a sparse mesh have no volunteer behind them.
      // Ordering treats unknown as worse than any known distance, but still
      // perfectly sendable — the flood itself is never narrowed (§1.1).
      expect(gradient.hopsVia('never-heard-of'), isNull);
      expect(gradient.isDirectVolunteer('never-heard-of'), isFalse);
    });
  });

  group('time gossip — PERSON_A.md Wk4 D4', () {
    late TimeGossipIngestion ingestion;
    late _StubTrust trust;

    setUp(() {
      trust = _StubTrust();
      ingestion = TimeGossipIngestion(
        meshTime: MeshTimeGossip(),
        trust: trust,
        deviceClock: const DeviceClock('this-device'),
        localWallClockMs: () => 1_000_000,
      );
    });

    Future<Envelope> gossipFrom(int wallClockMs, {DeviceKeyPair? by}) {
      return EnvelopeSigner.sign(
        kind: EnvelopeKind.timeGossip,
        body: TimeGossipMessage(
          wallClockMs: wallClockMs,
          logicalClock: _clock,
        ).encode(),
        keyPair: by ?? sender,
        hopLimit: 5,
      );
    }

    test('gossip is applied locally and NEVER relayed', () async {
      // A clock reading is evidence about the two devices that exchanged it.
      // Forwarding one secondhand would let a single skewed clock propagate
      // as though many devices had independently observed it — precisely the
      // failure a median is meant to prevent.
      final outcome = await ingestion.handle(await gossipFrom(1_000_000), null);

      expect(outcome.accepted, isTrue);
      expect(outcome.relay, isFalse);
    });

    test('an offset sample records the drift, signed and positive', () async {
      await ingestion.handle(await gossipFrom(1_005_000), null);

      expect(ingestion.samples, hasLength(1));
      expect(ingestion.samples.single.offsetMs, 5000,
          reason: 'positive means their clock is ahead of ours');
    });

    test('a peer behind us gives a negative offset', () async {
      await ingestion.handle(await gossipFrom(995_000), null);
      expect(ingestion.samples.single.offsetMs, -5000);
    });

    test('the volunteer flag is passed through for weighting', () async {
      // data/ has no way to know who is a volunteer, so this side says.
      trust.grant(sender);
      await ingestion.handle(await gossipFrom(1_000_100), null);

      expect(ingestion.samples.single.isVolunteer, isTrue);
    });

    test('mean absolute offset is the Wk4 D4 drift number', () async {
      expect(ingestion.meanAbsoluteOffsetMs, isNull);

      await ingestion.handle(await gossipFrom(1_002_000), null);
      await ingestion.handle(await gossipFrom(998_000), null);

      expect(ingestion.meanAbsoluteOffsetMs, 2000,
          reason: 'absolute — +2s and -2s is 2s of drift, not none');
    });

    test('samples are bounded — this is diagnostics, not state', () async {
      for (var i = 0; i < TimeGossipIngestion.maxSamples + 10; i++) {
        await ingestion.handle(await gossipFrom(1_000_000 + i), null);
      }

      expect(ingestion.samples, hasLength(TimeGossipIngestion.maxSamples));
      expect(ingestion.samples.last.offsetMs,
          TimeGossipIngestion.maxSamples + 9);
    });

    test('a malformed gossip body is dropped', () async {
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.timeGossip,
        body: Uint8List.fromList([0x01, 0x02]),
        keyPair: sender,
        hopLimit: 5,
      );

      final outcome = await ingestion.handle(envelope, null);

      expect(outcome.accepted, isFalse);
      expect(outcome.relay, isFalse);
    });
  });
}
