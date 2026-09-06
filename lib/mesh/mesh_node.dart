// lib/mesh/mesh_node.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../data/models/claim.dart';
import '../data/time/mesh_time.dart';
import '../identity/keypair.dart';
import '../identity/node_trust.dart';
import '../identity/vouch_registry.dart';
import 'beacon_ingestion.dart';
import 'claim_ingestion.dart';
import 'envelope.dart';
import 'envelope_router.dart';
import 'envelope_signer.dart';
import 'message_handler.dart';
import 'mesh_transport.dart';
import 'messages/beacon_message.dart';
import 'messages/resolution_message.dart';
import 'messages/revocation_message.dart';
import 'messages/time_gossip_message.dart';
import 'messages/vouch_message.dart';
import 'pending_resolutions.dart';
import 'receive_pipeline.dart';
import 'relay_queue.dart';
import 'resolution_ingestion.dart';
import 'routing_policy.dart';
import 'seen_message_cache.dart';
import 'time_gossip_ingestion.dart';
import 'trust_message_ingestion.dart';
import 'volunteer_gradient.dart';

/// Counters for what the node did with inbound traffic.
///
/// Kept because the failure modes of a mesh are invisible otherwise: on a
/// device with no console, "nothing is arriving" and "everything is arriving
/// and being rejected" look identical from the map.
class MeshNodeStats {
  int framesReceived = 0;
  int undecodable = 0;
  int duplicates = 0;
  int signatureInvalid = 0;
  int stored = 0;
  int ingestRejected = 0;
  int relayed = 0;

  /// Accepted counts by envelope kind. Without this, a phone that is happily
  /// relaying claims but silently rejecting every beacon looks identical to
  /// one where nobody is beaconing at all.
  final Map<EnvelopeKind, int> acceptedByKind = {};

  /// The last rejection reason seen per kind. One slot, not a log: this is
  /// read off `adb logcat` during a bring-up run, and the most recent reason
  /// is the one being chased.
  final Map<EnvelopeKind, String> lastRejectionByKind = {};

  void noteOutcome(EnvelopeKind kind, MessageOutcome outcome) {
    if (outcome.accepted) {
      acceptedByKind[kind] = (acceptedByKind[kind] ?? 0) + 1;
    } else if (outcome.reason != null) {
      lastRejectionByKind[kind] = outcome.reason!;
    }
  }

  String get byKind => acceptedByKind.entries
      .map((e) => '${e.key.name}=${e.value}')
      .join(' ');

  @override
  String toString() =>
      'rx=$framesReceived undecodable=$undecodable dup=$duplicates '
      'badsig=$signatureInvalid stored=$stored rejected=$ingestRejected '
      'relayed=$relayed${byKind.isEmpty ? '' : ' [$byKind]'}';
}

/// Wires the radio to the data layer — Phase 2's whole point, extended in
/// Phase 3 and 4 to every message kind in CLAIM_SCHEMA.md §9.1.
///
/// Inbound: transport -> decode -> [ReceivePipeline] (de-dup, verify, hop
/// decrement) -> [EnvelopeRouter] (per-kind handling) -> [RelayQueue].
/// Outbound: [originate] signs a local claim and queues it for flood; the
/// `originate*` methods beside it do the same for kinds 2–6.
///
/// **This class creates no corroboration, ever.** Receiving and forwarding a
/// claim teaches this device nothing about whether it is true — CLAUDE.md
/// §2.2. Trust moves only on independent generation or a human explicitly
/// attesting, and neither can happen on the receive path. If a future change
/// makes this class touch `claim_trust`, that change is the bug.
class MeshNode {
  final MeshTransport transport;
  final ClaimIngestion ingestion;
  final DeviceKeyPair keyPair;
  final RoutingPolicy policy;
  final RelayQueue relayQueue;
  final MeshNodeStats stats = MeshNodeStats();

  /// Which neighbours have a volunteer behind them — PERSON_A.md Wk4 D3.
  final VolunteerGradient gradient;

  /// The web of trust this device has heard. Also the answer to "am I a
  /// volunteer", which decides whether this node beacons at all.
  final VouchRegistry vouchRegistry;

  final EnvelopeRouter router;

  /// Built in the constructor body rather than the initialiser list: its
  /// callbacks are instance methods, and `this` is not available before then.
  late final ReceivePipeline pipeline;

  StreamSubscription<InboundFrame>? _subscription;

  /// Monotonic beacon counter. Freshness with no clock — see [BeaconMessage].
  int _beaconSeq = 0;

  /// Serialises frame handling. Two frames processed concurrently would
  /// interleave the pipeline's store-then-relay sequence, and [_relay] reads
  /// state that [_store] just wrote. A radio delivers frames whenever it
  /// likes; correctness here must not depend on them arriving one at a time.
  Future<void> _chain = Future<void>.value();

  /// Set by [_handleFrame], read by [_store], for the frame currently in
  /// flight.
  ///
  /// Instance state rather than a pipeline parameter for the same reason
  /// [_pendingRelay] is: the chain above guarantees exactly one frame is in
  /// flight, and threading the inbound peer through [ReceivePipeline] would
  /// change a signature every handler and test double depends on, to carry a
  /// value only the beacon handler reads. If frame handling ever stops being
  /// serialised, both of these become races — that is the thing to check
  /// before touching [_chain].
  RelayTarget? _pendingFrom;

  /// Set by [_store], read by [_relay], for the frame currently in flight.
  bool _pendingRelay = true;

  /// A factory rather than a generative constructor because the defaults are
  /// *shared*: the gradient the beacon handler writes to has to be the same
  /// object the relay queue orders by, and the registry the vouch handler
  /// writes to has to be the same one the beacon handler reads. Building them
  /// in an initialiser list would quietly produce a second copy of each — a
  /// node that learns routes into an object nothing ever consults.
  factory MeshNode({
    required MeshTransport transport,
    required ClaimIngestion ingestion,
    required DeviceKeyPair keyPair,
    SeenMessageCache? seenCache,
    RoutingPolicy policy = const RoutingPolicy(),
    VolunteerGradient? gradient,
    VouchRegistry? vouchRegistry,
    EnvelopeRouter? router,
    MeshTimeGossip? meshTime,
  }) {
    final sharedGradient = gradient ?? VolunteerGradient();
    final sharedRegistry = vouchRegistry ?? VouchRegistry();

    return MeshNode._(
      transport: transport,
      ingestion: ingestion,
      keyPair: keyPair,
      seenCache: seenCache,
      policy: policy,
      gradient: sharedGradient,
      vouchRegistry: sharedRegistry,
      router: router ??
          _defaultRouter(
            ingestion: ingestion,
            gradient: sharedGradient,
            registry: sharedRegistry,
            policy: policy,
            meshTime: meshTime ?? MeshTimeGossip(),
          ),
    );
  }

  MeshNode._({
    required this.transport,
    required this.ingestion,
    required this.keyPair,
    required this.router,
    required this.vouchRegistry,
    required RoutingPolicy policy,
    required VolunteerGradient gradient,
    SeenMessageCache? seenCache,
  })  : policy = policy,
        gradient = gradient,
        relayQueue = RelayQueue(
          sender: _senderFor(transport),
          policy: policy,
          gradient: gradient,
        ) {
    pipeline = ReceivePipeline(
      seenCache: seenCache ?? SeenMessageCache(),
      store: _store,
      relay: _relay,
    );
  }

  /// The standard set of handlers.
  ///
  /// Assembled from what [ClaimIngestion] already carries — its repository
  /// and device clock — rather than asking every caller for them again. A
  /// caller with different needs passes its own `router`.
  static EnvelopeRouter _defaultRouter({
    required ClaimIngestion ingestion,
    required VolunteerGradient gradient,
    required VouchRegistry registry,
    required RoutingPolicy policy,
    required MeshTimeGossip meshTime,
  }) {
    final resolutions = ResolutionIngestion(
      repository: ingestion.repository,
      pending: PendingResolutionStore(),
      deviceClock: ingestion.deviceClock,
      trust: registry,
    );

    return EnvelopeRouter(
      claims: ingestion,
      resolutions: resolutions,
      vouches: VouchIngestion(
        registry: registry,
        deviceClock: ingestion.deviceClock,
      ),
      revocations: RevocationIngestion(
        registry: registry,
        deviceClock: ingestion.deviceClock,
      ),
      beacons: BeaconIngestion(
        gradient: gradient,
        trust: registry,
        deviceClock: ingestion.deviceClock,
        policy: policy,
      ),
      timeGossip: TimeGossipIngestion(
        meshTime: meshTime,
        trust: registry,
        deviceClock: ingestion.deviceClock,
      ),
    );
  }

  static PeerSender _senderFor(MeshTransport transport) {
    return (RelayTarget target, Envelope envelope) =>
        transport.send(target, envelope.encode());
  }

  Future<void> start() async {
    await transport.start();
    _subscription = transport.inbound.listen(_onFrame);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await transport.stop();
  }

  /// Completes when every frame accepted so far has finished processing.
  ///
  /// The receive path is chained rather than awaited by the caller — a radio
  /// hands frames over whenever it likes — so this is the only way to know the
  /// node has caught up. Tests need it; so does an orderly shutdown.
  Future<void> get idle => _chain;

  /// What this device is allowed to do, from the vouch web it has heard.
  Future<NodeCapabilities> get capabilities =>
      vouchRegistry.capabilitiesOf(keyPair.publicKey);

  void _onFrame(InboundFrame frame) {
    _chain = _chain.then((_) => _handleFrame(frame));
  }

  Future<void> _handleFrame(InboundFrame frame) async {
    stats.framesReceived++;

    // Never throws by contract — a malformed packet from a stranger is
    // ordinary traffic on this transport, not an exception (see
    // EnvelopeDecodeResult).
    final decoded = Envelope.decode(frame.bytes);
    if (decoded is! EnvelopeDecodeOk) {
      stats.undecodable++;
      return;
    }

    _pendingFrom = frame.from;
    _pendingRelay = true;
    final outcome = await pipeline.receive(decoded.envelope);
    _pendingFrom = null;

    switch (outcome) {
      case ReceiveOutcome.duplicate:
        stats.duplicates++;
      case ReceiveOutcome.signatureInvalid:
        stats.signatureInvalid++;
      case ReceiveOutcome.storedHopLimitReached:
      case ReceiveOutcome.storedAndRelayed:
        break;
    }
  }

  Future<void> _store(Envelope envelope) async {
    final outcome = await router.route(envelope, _pendingFrom);
    _pendingRelay = outcome.relay;
    stats.noteOutcome(envelope.kind, outcome);

    if (outcome.accepted) {
      stats.stored++;
    } else {
      stats.ingestRejected++;
    }
  }

  Future<void> _relay(Envelope envelope) async {
    // A valid signature proves who wrote the bytes, not that they told the
    // truth about themselves, and not that they were entitled to say it.
    // Handlers catch what the signature cannot: a claim naming someone else's
    // device id, a claim whose id was not computed by §2's rules, a beacon
    // from a key nobody has vouched for. Forwarding one of those would make
    // this device an honest amplifier for an attack — §9.3's "invalid: do not
    // relay" applies to them for the same reason it applies to a bad
    // signature.
    //
    // Note what is *not* in that set: a message this device could not act on
    // because of what it happens to know. A vouch from an unrecognised
    // voucher, a revocation for a vouch never heard, a claim already held —
    // all still travel, because the next device along may be the one that can
    // use them. See MessageOutcome for the split.
    if (!_pendingRelay) return;

    if (relayQueue.enqueue(envelope)) stats.relayed++;
  }

  /// Signs a locally raised claim and queues it for flood.
  ///
  /// `hopLimit` comes from routing policy per claim type, so an SOS starts
  /// with the reach an SOS needs. The claim must already be stored locally by
  /// `data/` — this is the transmit path, not a second way to write to the
  /// store.
  Future<Envelope> originate(Claim claim) {
    return _originate(
      kind: EnvelopeKind.claim,
      body: Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
      hopLimit: policy.initialHopLimitFor(claim.type),
    );
  }

  /// Signs and floods a QR resolution — PERSON_A.md Wk3 D3.
  ///
  /// The envelope signature *is* the volunteer's counter-signature: it covers
  /// the whole body, and the body already carries the requester's signature
  /// over `sosId || nonce`. Two signatures, one envelope, and every hop
  /// verifies both before applying anything (CLAIM_SCHEMA.md §6.2).
  Future<Envelope> originateResolution(ResolutionMessage resolution) {
    return _originate(
      kind: EnvelopeKind.resolution,
      body: resolution.encode(),
      hopLimit: policy.initialHopLimitForKind(EnvelopeKind.resolution),
    );
  }

  /// Signs and floods a vouch — PERSON_A.md Wk4 D1.
  Future<Envelope> originateVouch(VouchMessage vouch) {
    return _originate(
      kind: EnvelopeKind.vouch,
      body: vouch.encode(),
      hopLimit: policy.initialHopLimitForKind(EnvelopeKind.vouch),
    );
  }

  /// Signs and floods a revocation — PERSON_A.md Wk4 D2.
  Future<Envelope> originateRevocation(RevocationMessage revocation) {
    return _originate(
      kind: EnvelopeKind.revocation,
      body: revocation.encode(),
      hopLimit: policy.initialHopLimitForKind(EnvelopeKind.revocation),
    );
  }

  /// Emits one volunteer beacon, if this device is actually a volunteer —
  /// PERSON_A.md Wk4 D3.
  ///
  /// Returns null when it is not. **The check is not decoration:** a beacon
  /// from a device the mesh has not vouched for is dropped by every receiver
  /// ([BeaconIngestion]), so emitting one would spend radio time and battery
  /// to be ignored — and a node that beaconed anyway would look, in a log,
  /// exactly like the attack that check exists to stop.
  Future<Envelope?> emitBeacon() async {
    if (!(await capabilities).isVolunteer) return null;

    final beacon = BeaconMessage(
      beaconSeq: ++_beaconSeq,
      logicalClock: await ingestion.deviceClock.tickForSend(),
    );

    return _originate(
      kind: EnvelopeKind.volunteerBeacon,
      body: beacon.encode(),
      hopLimit: policy.initialHopLimitForKind(EnvelopeKind.volunteerBeacon),
    );
  }

  /// Exchanges clock readings with the neighbours already connected —
  /// PERSON_A.md Wk4 D4.
  ///
  /// **Piggybacks, never dials.** It writes only to peers the transport
  /// already has, and opens nothing. That is a battery decision rather than a
  /// nicety: one BLE connection is a connect, a negotiate, a write and a
  /// disconnect — hundreds of milliseconds of radio — and spending that to
  /// swap a timestamp on a phone budgeted for 72 hours is exactly the trade
  /// CLAUDE.md §1.1 says to make the other way round.
  ///
  /// It also bypasses [relayQueue] on purpose: routing policy says gossip is
  /// never relayed, so the queue would refuse it. This is a direct write to
  /// whoever is already there.
  Future<int> gossipTime() async {
    final peers = transport.peers;
    if (peers.isEmpty) return 0;

    final message = TimeGossipMessage(
      wallClockMs: DateTime.now().millisecondsSinceEpoch,
      logicalClock: await ingestion.deviceClock.tickForSend(),
    );

    final envelope = await EnvelopeSigner.sign(
      kind: EnvelopeKind.timeGossip,
      body: message.encode(),
      keyPair: keyPair,
      hopLimit: policy.initialHopLimitForKind(EnvelopeKind.timeGossip),
    );
    await pipeline.seenCache.record(envelope.msgId);

    var sent = 0;
    for (final peer in peers) {
      if (await transport.send(peer, envelope.encode())) sent++;
    }
    return sent;
  }

  /// Signs a body, records it as seen, and queues it for flood.
  Future<Envelope> _originate({
    required EnvelopeKind kind,
    required Uint8List body,
    required int hopLimit,
  }) async {
    final envelope = await EnvelopeSigner.sign(
      kind: kind,
      body: body,
      keyPair: keyPair,
      hopLimit: hopLimit,
    );

    // Recorded as seen before it leaves: when a neighbour floods it back, this
    // device must recognise its own message and drop it rather than storing a
    // second copy and re-relaying. Phase 0 confirmed this behaviour on real
    // hardware (PERSON_A.md Day 1-2).
    await pipeline.seenCache.record(envelope.msgId);

    relayQueue.enqueue(envelope);
    return envelope;
  }

  /// Pushes everything queued out over the radio, volunteer-ward first.
  ///
  /// Called explicitly rather than on a timer: duty-cycled scheduling is Week
  /// 4 Day 5 work and needs real battery numbers behind it, which Phase 0 has
  /// not produced yet.
  Future<int> flush() {
    // Routes are dropped before ordering, not on a timer: an expired entry
    // that survives one drain is a message sent confidently in the direction
    // of a volunteer who has gone.
    gradient.expireBefore(DateTime.now().millisecondsSinceEpoch);
    return relayQueue.drain(transport.peers);
  }
}
