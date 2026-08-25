// lib/mesh/routing_policy.dart

import 'package:cbor/cbor.dart';

import '../data/enums.dart';
import 'envelope.dart';

/// What the relay layer should do with an envelope that already survived the
/// receive pipeline (de-duped, signature-verified, hops remaining).
enum RelayDecision {
  /// Every device forwards, every time. The message is life-critical and a
  /// missed forward can cost a rescue.
  flood,

  /// Forwarded, but it is the first thing sacrificed when the radio falls
  /// behind. See [RelayQueue] — selective traffic is droppable, flood is not.
  selective,

  /// Not forwarded at all. Still stored locally if the pipeline stored it —
  /// "do not relay" is not "discard" (CLAUDE.md §1.1).
  doNotRelay,
}

/// Routing policy — PERSON_A.md Week 2 Day 5.
///
/// Decides *whether* and *how eagerly* a message travels onward. The receive
/// pipeline decides whether relay is permissible at all (de-dup, signature,
/// hop limit); this decides what to do with that permission.
///
/// **On reading claim type inside `mesh/`:** PERSON_A.md §1 says a `claimType`
/// branch outside routing policy means the transport has drifted into B's
/// territory. Routing policy is the sanctioned exception — a flood decision
/// is meaningless without knowing whether the payload is an SOS or a sack of
/// rice. It peeks one field and interprets nothing else.
class RoutingPolicy {
  const RoutingPolicy();

  /// Initial `hopLimit` stamped on a locally originated claim.
  ///
  /// **PROVISIONAL — CLAUDE.md §8 open question.** These are not derived from
  /// measurement, because the measurement does not exist yet: Phase 0 answered
  /// single-hop write range (~50 m outdoors, no boundary found indoors) but
  /// 3b — relay across real distance — has never been run, so nobody knows what
  /// one hop buys in the field. Ordering between the types is a genuine design
  /// decision and is safe to keep; the absolute numbers are placeholders.
  ///
  /// Do not quietly harden these into "the values". They need a walked,
  /// marked-distance 3b run behind them, and per §8 that is a team decision,
  /// not a routing-layer one.
  static const int sosHopLimit = 8;
  static const int hazardHopLimit = 5;
  static const int resourceHopLimit = 3;

  /// SOS travels furthest, resource least. An SOS that stops one hop short of
  /// a volunteer is a person not found; a resource pin that stops short is a
  /// stale count someone corrects later.
  int initialHopLimitFor(ClaimType type) {
    switch (type) {
      case ClaimType.sos:
      case ClaimType.sosProxy:
        return sosHopLimit;
      case ClaimType.hazardReport:
        return hazardHopLimit;
      case ClaimType.resource:
        return resourceHopLimit;
    }
  }

  /// Relay decision for an inbound envelope.
  ///
  /// A `claim` envelope whose type cannot be read falls back to [
  /// RelayDecision.flood] rather than being dropped. That asymmetry is
  /// deliberate: the pipeline already proved the signature, so this is a
  /// well-formed message this version simply cannot classify. Refusing to
  /// forward it would let a future claim type silently stop propagating on
  /// older devices — and if it is an SOS, §1.1 says the cost of guessing
  /// wrong in the cautious direction is unacceptable. Relaying one extra
  /// message costs battery; not relaying one costs a rescue.
  RelayDecision decide(Envelope envelope) {
    switch (envelope.kind) {
      case EnvelopeKind.claim:
        final type = peekClaimType(envelope.body);
        if (type == null) return RelayDecision.flood;
        return _decideForClaimType(type);

      // Moves trust on arrival, so it has to reach the same devices the claim
      // reached — a corroboration that stops short leaves a claim looking
      // less believed than it is.
      case EnvelopeKind.corroboration:
        return RelayDecision.flood;

      // Floods back through the mesh like the original SOS (PERSON_A.md Wk3
      // D3). A resolution that stops short leaves the claim active forever on
      // every device past that point, and volunteers keep being dispatched to
      // someone already rescued.
      case EnvelopeKind.resolution:
        return RelayDecision.flood;

      // Revocation must outrun the vouch it cancels, so it cannot be the
      // droppable class (§4.5 identity checklist: "revocation propagates and
      // overrides"). Vouches flood alongside it — a provisional volunteer
      // whose vouch stalled is invisible as a volunteer.
      case EnvelopeKind.vouch:
      case EnvelopeKind.revocation:
        return RelayDecision.flood;

      // Week 4 work. Beacons are re-broadcast to build the hop gradient, but
      // they are periodic and self-replacing: a dropped beacon is corrected by
      // the next one, so they must never crowd out claim traffic.
      case EnvelopeKind.volunteerBeacon:
        return RelayDecision.selective;

      // Exchanged directly between two devices that meet, piggybacked on a
      // connection that already exists (PERSON_A.md Wk4 D4). Flooding a clock
      // reading is meaningless — it is only evidence about the pair that
      // exchanged it, and forwarding it secondhand would let one skewed clock
      // propagate as though many devices had observed it.
      case EnvelopeKind.timeGossip:
        return RelayDecision.doNotRelay;
    }
  }

  RelayDecision _decideForClaimType(ClaimType type) {
    switch (type) {
      // Full flood — every device relays, no exceptions, no conditions.
      // CLAUDE.md §1.1: where battery conflicts with keeping an SOS moving,
      // the SOS wins.
      case ClaimType.sos:
      case ClaimType.sosProxy:
        return RelayDecision.flood;

      // Hazards route people around danger, so they flood too. A blocked road
      // nobody heard about is a volunteer driving into it.
      case ClaimType.hazardReport:
        return RelayDecision.flood;

      // Selective — the one droppable claim type. A stale resource pin is an
      // inconvenience; availability is add-only and self-corrects as fresher
      // counts arrive (§7). This is the traffic that yields when the radio is
      // saturated, so SOS does not queue behind rice.
      case ClaimType.resource:
        return RelayDecision.selective;
    }
  }

  /// Reads the `type` field out of a claim's signed core without decoding the
  /// rest of it.
  ///
  /// Layout is `[id, type, deviceId, sequence, clock, payload, created]` —
  /// Claim.fromSignedCoreCbor. Returns null on anything unexpected; this runs
  /// on a stranger's bytes, so it reports failure rather than throwing
  /// (see EnvelopeDecodeResult for the same rule at the envelope level).
  static ClaimType? peekClaimType(List<int> body) {
    try {
      final decoded = cbor.decode(body);
      if (decoded is! CborList || decoded.length < 2) return null;
      final typeField = decoded[1];
      if (typeField is! CborSmallInt) return null;
      if (typeField.value < 0 || typeField.value >= ClaimType.values.length) {
        return null;
      }
      return ClaimType.values[typeField.value];
    } catch (_) {
      return null;
    }
  }
}
