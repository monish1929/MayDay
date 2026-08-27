// lib/mesh/claim_ingestion.dart

import 'package:cbor/cbor.dart';

import '../data/database/claim_repository.dart';
import '../data/enums.dart';
import '../data/identity/geohash_utils.dart';
import '../data/identity/report_identity.dart';
import '../data/identity/sos_identity.dart';
import '../data/models/claim.dart';
import '../data/models/corroboration.dart';
import '../data/trust_engine.dart';
import '../data/time/decay.dart';
import '../data/time/device_clock.dart';
import 'envelope.dart';
import 'envelope_signer.dart';
import 'routing_policy.dart';

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

/// What a merge did to the claim already held.
class MergeOutcome {
  final Claim claim;

  /// Whether this arrival was a second, independent author — i.e. whether a
  /// corroboration was recorded.
  final bool corroborated;

  const MergeOutcome(this.claim, {required this.corroborated});
}

class IngestResult {
  final Claim? stored;
  final IngestRejection? rejection;

  /// Set when the arrival combined with a claim already held rather than
  /// creating a new record.
  final MergeOutcome? merge;

  const IngestResult.stored(Claim claim)
      : stored = claim,
        rejection = null,
        merge = null;

  const IngestResult.rejected(IngestRejection reason)
      : stored = null,
        rejection = reason,
        merge = null;

  const IngestResult.merged(MergeOutcome outcome)
      : stored = null,
        rejection = null,
        merge = outcome;

  /// A merge is an accepted arrival: it changed the store.
  bool get accepted => stored != null || merge != null;
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

    final held = await repository.getClaim(claim.id);
    if (held != null) {
      return _merge(held, claim, envelope);
    }

    await repository.insertClaim(claim);
    return IngestResult.stored(claim);
  }

  /// Combines an arrival with a claim this device already holds.
  ///
  /// The whole question is whether the arrival is **new evidence** or merely
  /// the same evidence again.
  ///
  /// - **SOS / proxy SOS never merge.** Their ids come from
  ///   `hash(origin_device_id + sequence)`, so an identical id can only be the
  ///   very same claim coming round again. There is nothing to combine and no
  ///   witness to add (§2.1).
  /// - **Same author, mergeable type.** A hazard we already hold, reaching us
  ///   again by another path. The author has not observed anything twice; a
  ///   message arriving twice is not two people seeing a fire.
  /// - **Different author, mergeable type.** Two devices computed the same
  ///   `hash(type + geohash_bucket)` independently and each signed their own.
  ///   That is a second witness, and the one case in the whole receive path
  ///   that may touch trust.
  Future<IngestResult> _merge(Claim held, Claim arriving, Envelope envelope) async {
    // SOS never merges — §2.1, §2.3. Do not unify this with the branch below,
    // however similar the shapes look: the reason SOS ids are unique is
    // precisely so that two people in one geohash bucket stay two people.
    if (held.type == ClaimType.sos || held.type == ClaimType.sosProxy) {
      return const IngestResult.rejected(IngestRejection.alreadyHeld);
    }

    // Same author: no new information. This is the §2.2 case — a claim coming
    // back to us through the mesh teaches this device nothing it did not
    // already know, no matter how many times it arrives or how many devices
    // pass it along.
    if (arriving.originDeviceId == held.originDeviceId) {
      return const IngestResult.rejected(IngestRejection.alreadyHeld);
    }

    // A genuinely different device authored a matching claim and signed it
    // with its own key — the signature was already verified upstream, and
    // `matchesDeviceId` already proved the id space is its own. Independent
    // generation, per §2.2's first clause.
    //
    // `firstSeenVia` is null because this records what the AUTHOR did, and the
    // author generated it. The anti-echo field describes how a contributor
    // came to know a thing; an author that signed its own claim did not learn
    // it from us. This device's own echo-suppression is a separate concern and
    // lives on the attestation path, not here.
    await repository.insertCorroboration(
      held.id,
      Corroboration(
        deviceId: arriving.originDeviceId,
        hopDistance: _hopsTravelled(envelope, held.type),
        firstSeenVia: null,
        logicalClock: arriving.logicalClock,
        isVolunteer: false, // Beaconing is Week 4; nobody is a volunteer yet.
        kind: CorroborationKind.independentGeneration,
      ),
    );

    // Re-read so the freshly written corroboration is included, and so a
    // device that has already corroborated cannot be counted twice — the
    // table's primary key silently ignored the duplicate, and this is what
    // makes that visible to the trust computation.
    held.corroborations = await repository.getCorroborations(held.id);

    TrustEngine.recomputeTrustAndPriority(
      held,
      // Newcomer weighting needs a record of which devices were known before
      // this claim existed, which nothing tracks yet. `false` is the
      // permissive answer and therefore the wrong default to keep: it lets an
      // unknown device carry full weight. Flagged for B — see PERSON_A.md.
      isNewcomer: (_) => false,
    );
    await repository.updateClaim(held);

    return IngestResult.merged(MergeOutcome(held, corroborated: true));
  }

  /// How far the envelope travelled, from what is left of its hop limit.
  int _hopsTravelled(Envelope envelope, ClaimType type) {
    final initial = RoutingPolicy().initialHopLimitFor(type);
    final travelled = initial - envelope.hopLimit;
    // Never negative: a stranger can put any hopLimit it likes on the wire,
    // and a negative distance would invert the weighting so that the most
    // suspicious packet scored highest.
    return travelled < 0 ? 0 : travelled;
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
