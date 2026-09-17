// lib/mesh/resolution_ingestion.dart

import '../data/database/claim_repository.dart';
import '../data/enums.dart';
import '../data/models/claim.dart';
import '../data/time/device_clock.dart';
import '../identity/keypair.dart';
import '../identity/node_trust.dart';
import 'consumed_nonces.dart';
import 'envelope.dart';
import 'message_handler.dart';
import 'messages/body_codec.dart';
import 'messages/resolution_message.dart';
import 'pending_resolutions.dart';
import 'relay_queue.dart';

/// Applies `kind: 2` resolutions — PERSON_A.md Wk3 D3, CLAIM_SCHEMA.md §6.2.
///
/// **Both signatures are verified before anything is applied.** The envelope
/// signature (the volunteer's counter-signature) was checked by the receive
/// pipeline; the requester's signature over `sosId || nonce` is checked here,
/// because only here are the bytes decoded far enough to find it. A
/// resolution carrying one good signature and one forged one must not clear
/// an SOS — the pair is the entire proof that two devices were physically in
/// the same place.
///
/// A resolution for a claim this device does not hold is **parked, never
/// dropped** — see [PendingResolutionStore] for why that matters more than it
/// sounds.
class ResolutionIngestion implements MessageHandler {
  final ClaimRepository repository;
  final PendingResolutionStore pending;
  final DeviceClock deviceClock;

  /// Rescue codes already spent here — CLAUDE.md §6.2's replay row. See
  /// [ConsumedNonceStore] for why last-write-wins alone does not cover this.
  final ConsumedNonceStore consumedNonces;

  /// Consulted to record whether the counter-signer was a volunteer.
  final NodeTrustDirectory trust;

  /// Refuse a resolution whose counter-signer is not a volunteer.
  ///
  /// **Off, and that is a deliberate, flagged gap rather than an oversight.**
  /// PERSON_A.md Wk4 D4 requires "resolution signed by a non-volunteer key →
  /// rejected", and the check below is written and ready. It cannot be turned
  /// on yet because nothing can make a device a volunteer: the whole web of
  /// trust hangs off campaign-verified keys, and issuing those is B's Phase 4
  /// identity work (see `VouchRegistry`). With `trust_anchors` empty, every
  /// signer on earth is `unverified`, so enabling this would reject *every*
  /// resolution and leave every rescued person showing as still trapped.
  ///
  /// Turn it on in the same change that lands campaign credentials, not
  /// before, and not by default.
  final bool requireVolunteerCounterSignature;

  ResolutionIngestion({
    required this.repository,
    required this.pending,
    required this.deviceClock,
    required this.trust,
    ConsumedNonceStore? consumedNonces,
    this.requireVolunteerCounterSignature = false,
  }) : consumedNonces = consumedNonces ?? ConsumedNonceStore();

  @override
  Future<MessageOutcome> handle(Envelope envelope, RelayTarget? from) async {
    final decoded = ResolutionMessage.decode(envelope.body);
    if (decoded is BodyDecodeError<ResolutionMessage>) {
      return MessageOutcome.dropped('resolution: ${decoded.reason}');
    }
    final message = (decoded as BodyDecodeOk<ResolutionMessage>).body;

    // The requester's half. The envelope proved the *volunteer* signed these
    // bytes; nothing so far has proved the person in danger ever displayed
    // this QR. Without this check anyone could counter-sign a resolution they
    // wrote themselves and clear a live emergency.
    if (!await message.verifyRequesterSignature()) {
      return const MessageOutcome.dropped(
        'resolution: requester signature does not verify',
      );
    }

    // A code this device has already spent. Both signatures verify — they are
    // the same two signatures — so nothing before this point can tell a
    // photographed QR from the original. Refused rather than applied, but
    // still relayed: see below for why that is the safe direction.
    if (await consumedNonces.isConsumed(message.sosId, message.nonce)) {
      return const MessageOutcome(
        accepted: false,
        relay: true,
        reason: 'resolution: nonce already spent (replay)',
      );
    }

    if (requireVolunteerCounterSignature) {
      final signer = await trust.capabilitiesOf(envelope.originPubKey);
      if (!signer.canRespondToSos) {
        return const MessageOutcome.dropped(
          'resolution: counter-signer is not a volunteer',
        );
      }
    }

    // The originator has been heard from, so this device's clock must order
    // strictly after what it heard (§4).
    await deviceClock.observeReceive(message.resolvedAtLogical);

    final claim = await repository.getClaim(message.sosId);
    if (claim == null) {
      // Outran its own SOS. Park it and keep flooding: the neighbours past
      // this device may well hold the claim even though this one does not.
      await pending.park(message, resolverPubKey: envelope.originPubKey);
      return const MessageOutcome(
        accepted: true,
        relay: true,
        reason: 'resolution parked: claim not held yet',
      );
    }

    final applied = await applyTo(
      claim,
      message,
      resolverPubKey: envelope.originPubKey,
    );

    // Relayed either way. A resolution this device had already applied is
    // still news to somebody further out, and one that stops short leaves the
    // claim ACTIVE forever on every device past that point — SOS never
    // decays, so nothing else would ever clear it (§2.3).
    return MessageOutcome(
      accepted: applied,
      relay: true,
      reason: applied ? null : 'resolution superseded by a later one',
    );
  }

  /// Writes a resolution onto a claim this device holds.
  ///
  /// Also called from the claim path: when an SOS finally arrives for a
  /// resolution parked earlier, that is the same operation in the other
  /// order.
  Future<bool> applyTo(
    Claim claim,
    ResolutionMessage message, {
    required List<int> resolverPubKey,
  }) async {
    // Replay, checked again here because [applyTo] is also the volunteer's
    // own scan path (`RescueResolution.resolveFromScan`) and the parked-
    // resolution path, neither of which comes through [handle].
    if (await consumedNonces.isConsumed(message.sosId, message.nonce)) {
      return false;
    }

    // Last-write-wins by logical clock (§4). Two volunteers can genuinely
    // both scan — a mesh has no way to stop them — and the later
    // counter-signature is the one that describes what happened. This stays
    // safe alongside the nonce check above precisely because two genuine
    // scans mean two separate QR displays and therefore two different
    // nonces; a replay is the case where the nonce is the same.
    final held = claim.resolvedAtLogical;
    if (held != null && held.compareTo(message.resolvedAtLogical) >= 0) {
      return false;
    }

    claim.status = ClaimStatus.resolved;
    claim.resolutionMethod = message.method;
    claim.resolvedByVolunteerId =
        DeviceKeyPair.deviceIdForPublicKey(resolverPubKey);
    claim.resolvedAtLogical = message.resolvedAtLogical;

    // **Resolution moves `status`, and nothing else** — CLAIM_SCHEMA.md §6.1
    // keeps three fields for three questions. `claimTrust` is untouched here
    // on purpose: whether the claim was true is a separate question from
    // whether it is still open, and a volunteer arriving on site raises trust
    // through `TrustEngine.markGroundConfirmed`, which is B's call to make on
    // the flow side, not something the transport infers from a QR scan.
    //
    // `dispatchPriority` is likewise left alone. Downgrading it here would be
    // tempting and wrong: the field records how urgently a volunteer should
    // look, and rewriting history once the rescue is closed loses the record
    // of how it was handled.
    await repository.updateClaim(claim);
    await pending.discard(claim.id);

    // Spent only once it has actually changed something. Recording it earlier
    // — on receipt, say — would let a resolution that lost the logical-clock
    // race burn the nonce of the one that won.
    await consumedNonces.consume(message.sosId, message.nonce);
    return true;
  }

  /// Applies a resolution that was parked before its claim arrived.
  ///
  /// Returns true if one was waiting and has now been applied.
  Future<bool> applyPendingFor(Claim claim) async {
    final parked = await pending.take(claim.id);
    if (parked == null) return false;

    // Re-verified rather than trusted because it is in our own table. The row
    // was written from a message that had already passed both checks, but
    // re-running the cheap half costs nothing and means a corrupted or
    // tampered-with database file cannot close a live rescue.
    if (!await parked.message.verifyRequesterSignature()) {
      await pending.discard(claim.id);
      return false;
    }

    return applyTo(
      claim,
      parked.message,
      resolverPubKey: parked.resolverPubKey,
    );
  }
}
