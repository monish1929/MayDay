// lib/mesh/envelope_router.dart

import 'claim_ingestion.dart';
import 'envelope.dart';
import 'message_handler.dart';
import 'relay_queue.dart';
import 'resolution_ingestion.dart';

/// Dispatches a verified envelope to the handler for its kind —
/// CLAIM_SCHEMA.md §9.1's seven values, PERSON_A.md Wk3 D3 and Wk4 D1–D4.
///
/// **Why this exists at all.** Before it, the receive path handed every
/// envelope straight to [ClaimIngestion], which rejects anything that is not
/// `kind: 0` as a malformed body — and `MeshNode` then suppressed relay for
/// exactly that rejection. So a perfectly good, correctly signed vouch or
/// resolution was both discarded *and* stopped dead at the first device that
/// heard it. Adding a new message kind without adding a route for it here
/// silently reintroduces that, which is why the switch below is exhaustive
/// over [EnvelopeKind] rather than a map with a default.
class EnvelopeRouter {
  final ClaimIngestion claims;
  final ResolutionIngestion resolutions;
  final MessageHandler vouches;
  final MessageHandler revocations;
  final MessageHandler beacons;
  final MessageHandler timeGossip;

  EnvelopeRouter({
    required this.claims,
    required this.resolutions,
    required this.vouches,
    required this.revocations,
    required this.beacons,
    required this.timeGossip,
  });

  Future<MessageOutcome> route(Envelope envelope, RelayTarget? from) {
    switch (envelope.kind) {
      case EnvelopeKind.claim:
        return _handleClaim(envelope, from);

      case EnvelopeKind.corroboration:
        // **Not implemented, and deliberately still relayed.** A standalone
        // corroboration message — "I can see this too", §2.2's explicit
        // attestation — is B's data-side design and has no wire handler yet.
        // The envelope's signature is already verified, so this is a
        // well-formed message this build simply cannot apply; the same
        // reasoning `RoutingPolicy` uses for an unclassifiable claim applies
        // here. Dropping it would mean a device running an older build
        // silently severs corroboration for every device behind it.
        return Future.value(
          const MessageOutcome.relayOnly('corroboration: no handler yet'),
        );

      case EnvelopeKind.resolution:
        return resolutions.handle(envelope, from);
      case EnvelopeKind.vouch:
        return vouches.handle(envelope, from);
      case EnvelopeKind.revocation:
        return revocations.handle(envelope, from);
      case EnvelopeKind.volunteerBeacon:
        return beacons.handle(envelope, from);
      case EnvelopeKind.timeGossip:
        return timeGossip.handle(envelope, from);
    }
  }

  /// Adapts [ClaimIngestion]'s result to the shared outcome, and closes the
  /// resolution race in the direction the claim arrives second.
  Future<MessageOutcome> _handleClaim(
    Envelope envelope,
    RelayTarget? from,
  ) async {
    final result = await claims.ingest(envelope);

    final stored = result.stored;
    if (stored != null) {
      // The other half of PERSON_A.md Wk3 D3's last bullet. A resolution that
      // outran this claim was parked; now that the claim exists, it is
      // applied. Without this the parked row would sit there forever and the
      // rescue would show as active on this device for good — SOS never
      // decays, so nothing else clears it (§2.3).
      await resolutions.applyPendingFor(stored);
    }

    if (result.accepted) return const MessageOutcome.acceptedAndRelay();

    switch (result.rejection) {
      // Lies a signature cannot catch: a claim naming someone else's device
      // id, or one whose id was not computed by §2's rules. Forwarding either
      // would make this device an honest amplifier for an attack — §9.3's
      // "invalid: do not relay" covers these for the same reason it covers a
      // bad signature.
      case IngestRejection.deviceIdMismatch:
      case IngestRejection.forgedClaimId:
      case IngestRejection.malformedBody:
        return MessageOutcome.dropped('claim: ${result.rejection!.name}');

      // Not an attack: a genuine claim that reached us by another path with a
      // fresh msgId. Neighbours further out may still not have it.
      case IngestRejection.alreadyHeld:
      case null:
        return const MessageOutcome.relayOnly('claim already held');
    }
  }
}
