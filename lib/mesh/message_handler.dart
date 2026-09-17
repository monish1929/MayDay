// lib/mesh/message_handler.dart

import 'envelope.dart';
import 'relay_queue.dart';

/// What a handler did with one verified envelope.
///
/// Two independent answers, and conflating them is a real bug waiting to
/// happen:
///
/// - [accepted] — did this device's own state change?
/// - [relay] — should an honest device forward this to its neighbours?
///
/// They come apart constantly. A claim this device already holds is *not*
/// accepted (nothing changed) but must still be relayed, because a neighbour
/// further out may not have it. A claim naming someone else's device id is
/// neither: forwarding it would make this device an honest amplifier for a
/// lie the signature cannot catch (§9.3's "invalid: do not relay").
class MessageOutcome {
  final bool accepted;
  final bool relay;

  /// Why, in a few words. Ends up in the field log — on a phone with no
  /// console, "nothing is arriving" and "everything is arriving and being
  /// rejected" look identical from the map.
  final String? reason;

  const MessageOutcome({
    required this.accepted,
    required this.relay,
    this.reason,
  });

  /// Changed local state and should keep travelling.
  const MessageOutcome.acceptedAndRelay()
      : accepted = true,
        relay = true,
        reason = null;

  /// Nothing to do here, but neighbours further out may still need it.
  const MessageOutcome.relayOnly(String this.reason)
      : accepted = false,
        relay = true;

  /// Refused, and deliberately not forwarded. Use this only when relaying
  /// would spread something invalid — not merely when this device had no use
  /// for it.
  const MessageOutcome.dropped(String this.reason)
      : accepted = false,
        relay = false;

  /// Applied locally and deliberately not forwarded. Time gossip is the one
  /// message kind that ends here: a clock reading is evidence about the pair
  /// of devices that exchanged it and nothing more.
  const MessageOutcome.acceptedNoRelay()
      : accepted = true,
        relay = false,
        reason = null;
}

/// Handles one envelope kind.
///
/// Everything reaching a handler has already survived de-dup and signature
/// verification (CLAIM_SCHEMA.md §9.3 steps 1–2), so a handler never re-checks
/// the envelope signature. What it checks is everything a signature cannot
/// prove: that the signer was entitled to say this, that the ids inside match
/// the key that signed, that the content is well formed.
///
/// [from] is the neighbour the frame arrived through, or null for a locally
/// originated message replayed through the same path. Only the beacon handler
/// needs it — a gradient entry is meaningless without knowing which way it
/// points — but it is on the interface because threading it in later would
/// mean changing every handler.
abstract class MessageHandler {
  Future<MessageOutcome> handle(Envelope envelope, RelayTarget? from);
}
