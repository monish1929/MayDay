// lib/flows/rescue/sos_origination.dart

import 'package:cbor/cbor.dart';

import '../../data/claim_factory.dart';
import '../../data/database/claim_repository.dart';
import '../../data/enums.dart';
import '../../data/identity/sos_identity.dart';
import '../../data/models/claim.dart';
import '../../data/models/claim_payload.dart';
import '../../data/models/geo_point.dart';
import '../../mesh/envelope.dart';
import '../../mesh/mesh_node.dart';

/// Why an SOS could not be raised. Returned rather than thrown: the caller is
/// a person tapping a button in an emergency, and a stack trace is not an
/// answer they can act on.
enum SosOriginationFailure {
  /// The signed bytes could not be read back into a claim. Only reachable if
  /// the signing path itself is broken — but a claim that cannot be rebuilt
  /// must not reach the store as an unsigned original (§5).
  rebuildFailed,

  /// The id on the claim is not what §2's SOS rule produces. See
  /// [SosOrigination.raise] for why this is checked at all.
  identityRuleViolated,
}

class SosOriginationResult {
  final Claim? claim;
  final Envelope? envelope;
  final SosOriginationFailure? failure;

  const SosOriginationResult.raised(
    Claim this.claim,
    Envelope this.envelope,
  ) : failure = null;

  const SosOriginationResult.failed(this.failure)
      : claim = null,
        envelope = null;

  bool get raised => claim != null;
}

/// Raising an SOS: build, sign, store, flood — PERSON_A.md Wk3 D1.
///
/// The three sub-types are three payloads, **not** three code paths:
///
/// | | Who is in danger | Who is holding the phone |
/// |---|---|---|
/// | [raiseIndividual] | the person holding the phone | same person |
/// | [raiseGroup] | several people together | one of them |
/// | [raiseProxy] | someone whose phone is dead, lost or absent | a bystander |
///
/// Proxy SOS is the one that carries a `reporterDeviceId` and a location
/// *marked by the reporter* rather than sensed by the person in danger. It
/// exists because CLAUDE.md §9 is honest about the gap it half-closes: a
/// person with no phone and no reachable neighbour is outside this system's
/// reach, and a proxy report is the only thing that narrows that.
///
/// **What this is not:** "several people tagging into one shared SOS" is not
/// a data model here (MAYDAY_PROJECT_CONTEXT.md §4.1). Each person's SOS
/// stays a separate claim with its own id; nearby pins are grouped visually
/// and only visually. Group SOS means *one* person reporting a headcount, not
/// several claims fused into one.
class SosOrigination {
  final MeshNode node;
  final ClaimRepository repository;

  SosOrigination({required this.node, required this.repository});

  /// One person, one phone.
  Future<SosOriginationResult> raiseIndividual({
    required GeoPoint location,
  }) {
    return raise(SosPayload(location: location));
  }

  /// A group at one location, reported by one of them.
  ///
  /// `headcount` is a bucket rather than a number on purpose (§8,
  /// `HeadcountBucket`): "6–15" is what a frightened person on a roof can
  /// actually tell you, and a precise count would be a false precision that
  /// dispatch decisions then get made on.
  Future<SosOriginationResult> raiseGroup({
    required GeoPoint location,
    required HeadcountBucket headcount,
  }) {
    return raise(SosPayload(location: location, headcount: headcount));
  }

  /// Someone else's emergency, raised on their behalf.
  ///
  /// `reporterDeviceId` is this device — the one that can be asked about it
  /// afterwards. It is a distinct field from `originDeviceId` even when the
  /// two are equal, because a proxy claim can itself be relayed onward by a
  /// third party, and losing track of who actually saw the person is losing
  /// the only provenance the claim has.
  ///
  /// `note` is capped at 80 characters by §9.2's size budget; anything longer
  /// is truncated rather than refused. An SOS that fails to send because
  /// somebody typed too much is not an acceptable failure mode.
  Future<SosOriginationResult> raiseProxy({
    required GeoPoint location,
    required String reporterDeviceId,
    HeadcountBucket? headcount,
    String? note,
  }) {
    return raise(SosProxyPayload(
      location: location,
      headcount: headcount,
      reporterDeviceId: reporterDeviceId,
      proxyNote: note == null || note.length <= _maxNoteLength
          ? note
          : note.substring(0, _maxNoteLength),
    ));
  }

  /// §9.2 caps free text at 80 characters so the envelope stays under 400
  /// bytes on a transport whose practical write is ~512.
  static const int _maxNoteLength = 80;

  /// The shared body of all three: create, sign, verify identity, store,
  /// queue for flood.
  ///
  /// **`originate` signs and queues but does not store**, so the local copy
  /// is rebuilt from the signed bytes exactly the way a receiving device
  /// builds its copy. Two consequences, both wanted: every device in the mesh
  /// ends up holding a byte-identical record, and the local copy carries a
  /// real signature. Persisting the pre-signature object instead would put an
  /// unsigned claim in the store, which §2.5 forbids and
  /// `ClaimRepository` throws on.
  Future<SosOriginationResult> raise(ClaimPayload payload) async {
    assert(
      payload is SosPayload || payload is SosProxyPayload,
      'SosOrigination raises SOS claims only — hazard and resource go through '
      'their own flows, and their ids come from a different rule (§2.1).',
    );

    final claim = await ClaimFactory.createClaim(
      payload: payload,
      originDeviceId: node.keyPair.deviceId,
    );

    // The id must come from hash(originDeviceId + sequence), never from the
    // merge hash — CLAUDE.md §2.1. This is checked here, on the *outbound*
    // path, even though `ClaimIngestion` already checks it on the inbound one.
    //
    // Not redundant: the inbound check protects this device from a stranger's
    // forged id; this one protects the whole mesh from a bug in our own
    // factory. They are different failures with the same symptom, and the
    // symptom is the worst one in the project — two people in one geohash
    // bucket collapsing into a single pin, so that resolving one rescue
    // silently clears the other person's call for help.
    if (claim.id !=
        generateSosClaimId(claim.originDeviceId, claim.originSequence)) {
      return const SosOriginationResult.failed(
        SosOriginationFailure.identityRuleViolated,
      );
    }

    final envelope = await node.originate(claim);

    final stored = Claim.fromSignedCoreCbor(
      cbor.decode(envelope.body),
      originSignature: envelope.originSig,
      hopLimit: envelope.hopLimit,
      // NULL, not a large number. SOS never decays — §2.3. A person trapped
      // alone is UNCONFIRMED precisely because nobody is nearby to corroborate
      // them, which is exactly why their claim must not age out.
      displayLifetime: null,
    );
    if (stored == null) {
      return const SosOriginationResult.failed(
        SosOriginationFailure.rebuildFailed,
      );
    }

    await repository.insertClaim(stored);
    return SosOriginationResult.raised(stored, envelope);
  }
}
