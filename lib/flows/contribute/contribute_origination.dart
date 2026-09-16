// lib/flows/contribute/contribute_origination.dart

import 'package:cbor/cbor.dart';

import '../../data/claim_factory.dart';
import '../../data/database/claim_repository.dart';
import '../../data/enums.dart';
import '../../data/models/claim.dart';
import '../../data/models/claim_payload.dart';
import '../../data/models/geo_point.dart';
import '../../data/time/decay.dart';
import '../../mesh/envelope.dart';
import '../../mesh/mesh_node.dart';

/// Why a resource pledge could not be raised. Returned rather than thrown: the
/// caller is a volunteer tapping a button in the field, and a stack trace is
/// not an answer they can act on.
enum ContributeOriginationFailure {
  /// The signed bytes could not be read back into a claim. Only reachable if
  /// the signing path itself is broken — but a claim that cannot be rebuilt
  /// must not reach the store as an unsigned original (§5).
  rebuildFailed,
}

/// The outcome of a resource-pledge origination attempt.
///
/// Mirrors [SosOriginationResult] in shape so the caller's error handling is
/// the same pattern everywhere — check [raised], then either use [claim] and
/// [envelope] or react to [failure].
class ContributeOriginationResult {
  final Claim? claim;
  final Envelope? envelope;
  final ContributeOriginationFailure? failure;

  const ContributeOriginationResult.raised(
    Claim this.claim,
    Envelope this.envelope,
  ) : failure = null;

  const ContributeOriginationResult.failed(this.failure)
      : claim = null,
        envelope = null;

  bool get raised => claim != null;
}

/// Raising a resource pledge: build, sign, store, flood — parallel to
/// [SosOrigination] in lib/flows/rescue/.
///
/// **No identity-rule check.** SOS claims use `hash(originDeviceId +
/// sequence)`, where a collision between two people would silently merge their
/// calls for help — so the outbound path checks the id it just built to catch
/// a factory bug before it reaches the mesh.
///
/// Resource claims use `generateMergeableClaimId(type, geohashBucket)` instead.
/// Two devices in the same bucket computing the same id is *correct* — that's
/// how independent pledges of the same resource type at the same location
/// merge into a single visible pin with a combined count (§2.1). Checking for
/// uniqueness here would reject exactly the case the merge-hash rule was
/// designed for.
///
/// **displayLifetime is non-null.** SOS claims pass `null` because a trapped
/// person's pin must never age out. Resource pledges decay — a 4-hour-old
/// "food available here" is actively misleading if the food is gone. The
/// lifetime comes from [displayLifetimeFor] in lib/data/time/decay.dart and
/// is currently [resourceDisplayLifetime] (4 hours, TBD for final value).
class ContributeOrigination {
  final MeshNode node;
  final ClaimRepository repository;

  ContributeOrigination({required this.node, required this.repository});

  /// Build, sign, store, and flood a resource pledge.
  ///
  /// [location] is the GPS or manual-tap position of the supply point.
  /// [category] is one of the canonical four (§8.1).
  /// [pledgedCount] is the volunteer-reported unit count.
  Future<ContributeOriginationResult> pledge({
    required GeoPoint location,
    required ResourceCategory category,
    required int pledgedCount,
  }) async {
    final payload = ResourcePayload(
      location: location,
      category: category,
      pledgedCount: pledgedCount,
      claimedReports: 0,
    );

    final claim = await ClaimFactory.createClaim(
      payload: payload,
      originDeviceId: node.keyPair.deviceId,
    );

    final envelope = await node.originate(claim);

    // Rebuild the local copy from the signed bytes exactly the way a receiving
    // device builds its copy, rather than persisting the pre-signature object.
    // Both phones then hold a byte-identical record, and the local copy
    // carries a real signature — an unsigned claim must never reach the store
    // (§2.5).
    //
    // displayLifetime is EXPLICIT here, not null like SOS. SOS never decays
    // (§2.3) because a person trapped alone is unconfirmed precisely because
    // nobody is nearby to corroborate them, and their pin must not age out.
    // Resource pledges are the opposite: a supply point that no longer exists
    // is worse than no pin at all, so they carry the decay window from
    // decay.dart (currently 4 hours).
    final stored = Claim.fromSignedCoreCbor(
      cbor.decode(envelope.body),
      originSignature: envelope.originSig,
      hopLimit: envelope.hopLimit,
      displayLifetime: displayLifetimeFor(ClaimType.resource),
    );

    if (stored == null) {
      return const ContributeOriginationResult.failed(
        ContributeOriginationFailure.rebuildFailed,
      );
    }

    // TODO: pledgedCount accumulation — STATUS AS OF 2026-09-16:
    // Verified by A: claim_repository.dart:74 does an unconditional ConflictAlgorithm.replace,
    // and the inbound mesh merge path (claim_ingestion.dart _merge()) has the same gap in a worse
    // form — it silently discards conflicting resource payloads entirely rather than replacing OR
    // adding. B has not ratified a fix after 3.5 weeks. A's recommendation (verified, not yet
    // applied): a separate insertOrMergeResourceClaim method rather than a conditional inside
    // insertClaim, per schema §2.1's rule against shared write paths that fork on type.
    // Proceeding with plain insertClaim as a timeboxed, documented interim risk — pledges from
    // different devices in the same geohash bucket will currently silently overwrite rather than
    // accumulate. This is NOT fixed by this class alone; do not remove this comment until
    // insertOrMergeResourceClaim (or equivalent) exists and this call is swapped to use it.
    await repository.insertClaim(stored);

    return ContributeOriginationResult.raised(stored, envelope);
  }
}
