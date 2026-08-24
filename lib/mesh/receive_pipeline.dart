// lib/mesh/receive_pipeline.dart

import 'envelope.dart';
import 'envelope_signer.dart';
import 'seen_message_cache.dart';

/// Hands a verified envelope to the data layer.
///
/// Deliberately opaque: `mesh/` moves signed bytes and does not decode
/// `body`. What a claim *means* — trust, decay, merging, identity — is
/// `data/`'s (CLAUDE.md §5.1). The pipeline guarantees only that anything
/// reaching this callback survived de-dup and signature verification.
typedef EnvelopeSink = Future<void> Function(Envelope envelope);

/// Forwards an envelope onward. Routing policy (full flood vs selective)
/// is Day 5's job; the pipeline only decides *whether* relay is allowed.
typedef EnvelopeRelay = Future<void> Function(Envelope envelope);

/// Why a received envelope ended where it did. Returned rather than logged so
/// callers and tests can assert on the path taken.
enum ReceiveOutcome {
  /// Step 1: `msgId` already in the cache. Dropped silently, not relayed.
  duplicate,

  /// Step 2: signature invalid, malformed, or missing. Not stored, not
  /// relayed — §9.3 is explicit that all three take the same path.
  signatureInvalid,

  /// Step 3: `hopLimit` exhausted. Stored locally, relay not attempted.
  storedHopLimitReached,

  /// Step 4: stored and forwarded.
  storedAndRelayed,
}

/// The receive pipeline — CLAIM_SCHEMA.md §9.3.
///
/// The order is not arbitrary. Verification lands **before** storage so a
/// malformed claim can never enter the store, and **before** relay so an
/// honest device cannot propagate a tampered one. Any reordering here is a
/// correctness bug, not a refactor.
class ReceivePipeline {
  final SeenMessageCache seenCache;
  final EnvelopeSink store;
  final EnvelopeRelay relay;

  ReceivePipeline({
    required this.seenCache,
    required this.store,
    required this.relay,
  });

  Future<ReceiveOutcome> receive(Envelope envelope) async {
    // 1. De-dup. Exits before verification: re-verifying something already
    //    handled is wasted battery on a device budgeted for 72 hours.
    if (await seenCache.hasSeen(envelope.msgId)) {
      return ReceiveOutcome.duplicate;
    }

    // 2. Verify. Never throws — a stranger's malformed packet is expected
    //    input on this transport, not an exception.
    if (!await EnvelopeSigner.verify(envelope)) {
      // Deliberately NOT recorded as seen. Otherwise anyone could fill the
      // de-dup cache with garbage msgIds and evict ids for real messages
      // still in flight, making the device re-accept and re-relay them.
      return ReceiveOutcome.signatureInvalid;
    }

    // Recorded only once it is known good, for the same reason.
    await seenCache.record(envelope.msgId);

    // 3. Decrement hopLimit.
    final remainingHops = envelope.hopLimit > 0 ? envelope.hopLimit - 1 : 0;

    // 4. Store, then relay.
    //
    // Storage happens even when hops are exhausted: this device is a valid
    // destination, and CLAUDE.md §1.1 says life-critical data is never
    // silently discarded. A hop limit bounds how far a message travels, not
    // whether the device holding it gets to keep it.
    await store(envelope);

    if (remainingHops <= 0) {
      return ReceiveOutcome.storedHopLimitReached;
    }

    // msgId is carried through unchanged. A fresh id would defeat de-dup at
    // every downstream device — see SeenMessageCache.
    await relay(Envelope(
      v: envelope.v,
      msgId: envelope.msgId,
      hopLimit: remainingHops,
      kind: envelope.kind,
      body: envelope.body,
      originPubKey: envelope.originPubKey,
      originSig: envelope.originSig,
    ));

    return ReceiveOutcome.storedAndRelayed;
  }
}
