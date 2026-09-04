// lib/mesh/mesh_node.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../data/models/claim.dart';
import '../identity/keypair.dart';
import 'claim_ingestion.dart';
import 'envelope.dart';
import 'envelope_signer.dart';
import 'mesh_transport.dart';
import 'receive_pipeline.dart';
import 'relay_queue.dart';
import 'routing_policy.dart';
import 'seen_message_cache.dart';

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

  @override
  String toString() =>
      'rx=$framesReceived undecodable=$undecodable dup=$duplicates '
      'badsig=$signatureInvalid stored=$stored rejected=$ingestRejected '
      'relayed=$relayed';
}

/// Wires the radio to the data layer — Phase 2's whole point.
///
/// Inbound: transport -> decode -> [ReceivePipeline] (de-dup, verify, hop
/// decrement) -> [ClaimIngestion] (store) -> [RelayQueue] (forward).
/// Outbound: [originate] signs a local claim and queues it for flood.
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

  /// Built in the constructor body rather than the initialiser list: its
  /// callbacks are instance methods, and `this` is not available before then.
  late final ReceivePipeline pipeline;

  StreamSubscription<InboundFrame>? _subscription;

  /// Serialises frame handling. Two frames processed concurrently would
  /// interleave the pipeline's store-then-relay sequence, and [_relay] reads
  /// state that [_store] just wrote. A radio delivers frames whenever it
  /// likes; correctness here must not depend on them arriving one at a time.
  Future<void> _chain = Future<void>.value();

  /// Set by [_store], read by [_relay], for the frame currently in flight.
  IngestRejection? _pendingRejection;

  MeshNode({
    required this.transport,
    required this.ingestion,
    required this.keyPair,
    SeenMessageCache? seenCache,
    this.policy = const RoutingPolicy(),
  })  : relayQueue = RelayQueue(
          sender: _senderFor(transport),
          policy: policy,
        ) {
    pipeline = ReceivePipeline(
      seenCache: seenCache ?? SeenMessageCache(),
      store: _store,
      relay: _relay,
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

    _pendingRejection = null;
    final outcome = await pipeline.receive(decoded.envelope);

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
    final result = await ingestion.ingest(envelope);
    _pendingRejection = result.rejection;
    if (result.accepted) {
      stats.stored++;
    } else {
      stats.ingestRejected++;
    }
  }

  Future<void> _relay(Envelope envelope) async {
    // A valid signature proves who wrote the bytes, not that they told the
    // truth about themselves. Ingestion catches two lies the signature cannot:
    // a claim naming someone else's device id, and a claim whose id was not
    // computed by §2's rules. Forwarding either one would make this device an
    // honest amplifier for an attack — §9.3's "invalid: do not relay" applies
    // to these for the same reason it applies to a bad signature.
    switch (_pendingRejection) {
      case IngestRejection.deviceIdMismatch:
      case IngestRejection.forgedClaimId:
      case IngestRejection.malformedBody:
        return;
      // Already held is not an attack: it is a genuine claim that reached us
      // by another path with a fresh msgId. Neighbours further out may still
      // not have it, so it keeps travelling.
      case IngestRejection.alreadyHeld:
      case null:
        break;
    }

    if (relayQueue.enqueue(envelope)) stats.relayed++;
  }

  /// Signs a locally raised claim and queues it for flood.
  ///
  /// `hopLimit` comes from routing policy per claim type, so an SOS starts
  /// with the reach an SOS needs. The claim must already be stored locally by
  /// `data/` — this is the transmit path, not a second way to write to the
  /// store.
  Future<Envelope> originate(Claim claim) async {
    final envelope = await EnvelopeSigner.sign(
      kind: EnvelopeKind.claim,
      body: Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
      keyPair: keyPair,
      hopLimit: policy.initialHopLimitFor(claim.type),
    );

    // Recorded as seen before it leaves: when a neighbour floods it back, this
    // device must recognise its own message and drop it rather than storing a
    // second copy and re-relaying. Phase 0 confirmed this behaviour on real
    // hardware (PERSON_A.md Day 1-2).
    await pipeline.seenCache.record(envelope.msgId);

    relayQueue.enqueue(envelope);
    return envelope;
  }

  /// Pushes everything queued out over the radio, volunteers first.
  ///
  /// Called explicitly rather than on a timer: duty-cycled scheduling is Week
  /// 4 work and needs real battery numbers behind it, which Phase 0 has not
  /// produced yet.
  Future<int> flush() => relayQueue.drain(transport.peers);
}
