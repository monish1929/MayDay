// lib/mesh/claim_ingestion.dart

import 'package:cbor/cbor.dart';

import '../data/database/claim_repository.dart';
import '../data/enums.dart';
import '../data/identity/geohash_utils.dart';
import '../data/identity/report_identity.dart';
import '../data/identity/sos_identity.dart';
import '../data/models/claim.dart';
import '../data/time/decay.dart';
import '../data/time/device_clock.dart';
import 'envelope.dart';
import 'envelope_signer.dart';

/// Why an inbound claim did not reach the store. Returned rather than thrown —
/// every one of these is an expected outcome on a transport where the sender
/// is a stranger's phone.
enum IngestRejection {
  /// `body` was not a decodable signed core.
  malformedBody,

  /// The claim named an `originDeviceId` that is not the id derived from the
  /// key that signed the envelope.
  deviceIdMismatch,

  /// `id` is not what §2's rule produces for this claim's own fields — the
  /// originator computed it dishonestly, or lifted it from another id space.
  forgedClaimId,

  /// Already held. SOS never merges (§2.1), so a repeat id is simply a
  /// duplicate rather than something to combine.
  alreadyHeld,
}

class IngestResult {
  final Claim? stored;
  final IngestRejection? rejection;

  const IngestResult.stored(Claim claim)
      : stored = claim,
        rejection = null;

  const IngestResult.rejected(IngestRejection reason)
      : stored = null,
        rejection = reason;

  bool get accepted => stored != null;
}

/// Turns a verified envelope into a stored claim — the `store` step of
/// CLAIM_SCHEMA.md §9.3 step 4.
///
/// This is the seam between `mesh/` and `data/`. The pipeline hands over
/// opaque bytes that it has already de-duped and signature-checked; this
/// class decodes them, applies the checks that need to read claim content,
/// and writes through B's repository.
///
/// **It deliberately creates no corroboration.** Receiving a relayed claim
/// teaches this device nothing — §2.2. Trust moves only on independent
/// generation or a human explicitly attesting, and neither happened here.
class ClaimIngestion {
  final ClaimRepository repository;
  final DeviceClock deviceClock;

  ClaimIngestion({required this.repository, required this.deviceClock});

  Future<IngestResult> ingest(Envelope envelope) async {
    if (envelope.kind != EnvelopeKind.claim) {
      return const IngestResult.rejected(IngestRejection.malformedBody);
    }

    final CborValue decoded;
    try {
      decoded = cbor.decode(envelope.body);
    } catch (_) {
      return const IngestResult.rejected(IngestRejection.malformedBody);
    }

    final claim = Claim.fromSignedCoreCbor(
      decoded,
      originSignature: envelope.originSig,
      hopLimit: envelope.hopLimit,
      displayLifetime: _displayLifetimeFor(decoded),
    );
    if (claim == null) {
      return const IngestResult.rejected(IngestRejection.malformedBody);
    }

    // The signature proved whoever holds originPubKey wrote these bytes. It
    // did not stop them writing someone else's device id into them.
    if (!EnvelopeSigner.matchesDeviceId(envelope, claim.originDeviceId)) {
      return const IngestResult.rejected(IngestRejection.deviceIdMismatch);
    }

    // ...nor stop them computing `id` dishonestly. For SOS this matters most:
    // a forged id lands in a stranger's id space, and resolving one rescue
    // could then clear another person's (§2).
    if (!_hasHonestId(claim)) {
      return const IngestResult.rejected(IngestRejection.forgedClaimId);
    }

    // Lamport rule: this device has now heard from the originator, so its own
    // clock must order strictly after what it heard (§4).
    await deviceClock.observeReceive(claim.logicalClock);

    if (await repository.getClaim(claim.id) != null) {
      // Mergeable types (hazard/resource) are supposed to combine here rather
      // than be dropped — confirmation counts and resource counters are
      // add-only (§8.1). That merge lives in data/ and is not built yet, so
      // this currently keeps what it already has rather than overwriting with
      // a remote copy. Overwriting would silently lose local counter state.
      return const IngestResult.rejected(IngestRejection.alreadyHeld);
    }

    await repository.insertClaim(claim);
    return IngestResult.stored(claim);
  }

  /// Recomputes `id` under §2's rules and checks the claim agrees.
  ///
  /// Two separate rules, never one function with a type branch inside — the
  /// split is the point (§2.1).
  bool _hasHonestId(Claim claim) {
    switch (claim.type) {
      case ClaimType.sos:
      case ClaimType.sosProxy:
        return claim.id ==
            generateSosClaimId(claim.originDeviceId, claim.originSequence);
      case ClaimType.hazardReport:
      case ClaimType.resource:
        return claim.id ==
            generateMergeableClaimId(
              claim.type,
              getGeohashBucket(claim.payload.location),
            );
    }
  }

  /// Decay window is the receiver's own policy, not the sender's: a hostile
  /// originator must not be able to ask for a longer life on the map than
  /// this device's rules allow (§7). Returns null for SOS, which never decays.
  Duration? _displayLifetimeFor(CborValue decoded) {
    if (decoded is! CborList || decoded.length < 2) return null;
    final typeField = decoded[1];
    if (typeField is! CborSmallInt) return null;
    if (typeField.value < 0 || typeField.value >= ClaimType.values.length) {
      return null;
    }
    return displayLifetimeFor(ClaimType.values[typeField.value]);
  }
}
