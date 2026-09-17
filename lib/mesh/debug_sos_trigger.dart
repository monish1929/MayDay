// lib/mesh/debug_sos_trigger.dart


import 'package:cbor/cbor.dart';
import 'package:flutter/foundation.dart';

import '../data/claim_factory.dart';
import '../data/database/claim_repository.dart';
import '../data/models/claim.dart';
import '../data/models/claim_payload.dart';
import '../data/enums.dart';
import '../data/models/geo_point.dart';
import '../data/time/decay.dart';
import '../flows/rescue/sos_origination.dart';
import 'mesh_node.dart';

/// Raises a real, signed SOS with no UI involved.
///
/// **Bring-up scaffolding, not a feature.** It exists because Phase 2 Day 4
/// needs a claim to cross two physical phones, and nothing can raise one yet:
/// C's rescue form still prints its payload instead of writing a claim
/// (PERSON_C.md Wk2 D1, unstarted). Rather than reach into `ui/`, which is
/// C's, `mesh/` provides its own trigger and deletes it the day the real form
/// lands.
///
/// Off unless explicitly built in:
///
///     flutter build apk --debug --dart-define=MAYDAY_DEBUG_SOS=true
///
/// The default is `false` so this can never reach a real build by accident. A
/// fake SOS on a real device during a real disaster is not a small bug.
class DebugSosTrigger {
  /// Compile-time flag, not a runtime setting — an operator cannot turn this
  /// on by tapping something.
  static const bool enabled =
      bool.fromEnvironment('MAYDAY_DEBUG_SOS', defaultValue: false);

  /// Where the fake SOS is placed.
  ///
  /// Both phones deliberately use the SAME coordinates, which puts them in one
  /// geohash bucket. That is the CLAUDE.md §6.2 case — the most important test
  /// in the repo — and it must produce **two distinct claims**, because SOS ids
  /// come from `hash(origin_device_id + sequence)` and never merge (§2.1).
  /// Change these and you stop testing the thing worth testing.
  static const GeoPoint testLocation = GeoPoint(lat: 12.9716, lon: 77.5946);

  /// Builds, signs, stores and queues one individual SOS.
  ///
  /// Returns the claim id so it can be matched against the other phone's store.
  static Future<String?> raise(MeshNode node) => _raiseSos(
        node,
        const SosPayload(location: testLocation),
        'SOS',
      );

  /// Group SOS — the same claim carrying a `HeadcountBucket` (PERSON_A.md
  /// Wk3 D1).
  ///
  /// Worth raising alongside the individual one during a bring-up run: it
  /// gets a **different** id despite the identical location, because SOS ids
  /// come from `hash(originDeviceId + sequence)` and never from the bucket
  /// (§2.1). Two pins here, not one, is the thing to look for.
  static Future<String?> raiseGroup(MeshNode node) => _raiseSos(
        node,
        const SosPayload(
          location: testLocation,
          headcount: HeadcountBucket.sixToFifteen,
        ),
        'GROUP SOS',
      );

  /// Proxy SOS — raised on behalf of someone whose phone is dead or absent.
  ///
  /// Carries `reporterDeviceId` and a location the reporter marked, rather
  /// than one the person in danger sensed.
  static Future<String?> raiseProxy(MeshNode node) => _raiseSos(
        node,
        SosProxyPayload(
          location: testLocation,
          reporterDeviceId: node.keyPair.deviceId,
          proxyNote: 'debug proxy',
        ),
        'PROXY SOS',
      );

  /// All three SOS sub-types through the real origination path.
  ///
  /// Raised back to back on purpose: three claims, three distinct ids, one
  /// geohash bucket. That is CLAUDE.md §6.2's most important test as it looks
  /// on real hardware, and the failure it guards against — three pins
  /// collapsing into one — is visible from the map without any tooling.
  static Future<void> raiseSosSuite(MeshNode node) async {
    await raise(node);
    await raiseGroup(node);
    await raiseProxy(node);
  }

  /// Raises an SOS through `SosOrigination` — the same path the real rescue
  /// flow uses, rather than a second implementation of it.
  ///
  /// The point of a bring-up trigger is to exercise the code that ships. When
  /// this file carried its own copy of the sign-rebuild-store dance, a bug in
  /// either copy was invisible from the other.
  static Future<String?> _raiseSos(
    MeshNode node,
    ClaimPayload payload,
    String label,
  ) async {
    if (!enabled) return null;

    final result = await SosOrigination(
      node: node,
      repository: ClaimRepository(),
    ).raise(payload);

    final claim = result.claim;
    if (claim == null) {
      debugPrint('[mayday.mesh] DEBUG $label failed: ${result.failure?.name}');
      return null;
    }

    debugPrint('[mayday.mesh] DEBUG $label raised: id=${claim.id} '
        'origin=${claim.originDeviceId} seq=${claim.originSequence} '
        'trust=${claim.claimTrust.name} hopLimit=${result.envelope!.hopLimit}');
    return claim.id;
  }

  /// Raises a hazard at the same spot, which is the CORROBORATION test.
  ///
  /// Hazards use `hash(type + geohash_bucket)`, so two phones reporting the
  /// same flood in the same bucket compute the SAME id and are supposed to
  /// merge -- the exact mirror of the SOS case, where colliding would be a
  /// disaster. When they merge, the second author is recorded as an
  /// independent-generation corroboration (Section 2.2).
  ///
  /// Note what this will NOT show on two phones: `corroboratedThreshold` is
  /// 2.0 against a 1.0 per-device cap, so CORROBORATED needs the author plus
  /// TWO independent witnesses. With two phones the claim correctly stays
  /// UNCONFIRMED with one corroboration recorded. That is the trust engine
  /// working, not failing -- seeing the tier flip needs a third device.
  static Future<String?> raiseHazard(MeshNode node) => _raise(
        node,
        const HazardReportPayload(
          location: testLocation,
          hazardType: HazardType.flood,
          confirmationCount: 1,
        ),
        'HAZARD',
      );

  /// Hazard and resource claims only — SOS goes through [_raiseSos].
  ///
  /// Two paths, deliberately, because the id rules are two rules (§2.1): this
  /// one produces a merge hash, and unifying them would be the exact
  /// "simplification" CLAUDE.md §5.3 warns about.
  static Future<String?> _raise(
    MeshNode node,
    ClaimPayload payload,
    String label,
  ) async {
    if (!enabled) return null;

    final claim = await ClaimFactory.createClaim(
      payload: payload,
      originDeviceId: node.keyPair.deviceId,
    );

    // Sign and queue for flood. This does not store — `originate` is the
    // transmit path only, and says so.
    final envelope = await node.originate(claim);

    // Store the local copy by rebuilding it from the signed bytes exactly the
    // way the receive path does, rather than persisting the pre-signature
    // object. Both phones then hold a byte-identical record of the same claim,
    // and the local copy carries a real signature — an unsigned claim must
    // never reach the store (§2.5).
    final stored = Claim.fromSignedCoreCbor(
      cbor.decode(envelope.body),
      originSignature: envelope.originSig,
      hopLimit: envelope.hopLimit,
      // The receiver's own policy, exactly as `ClaimIngestion` applies it to
      // an inbound claim — a locally raised hazard must not sit on the map
      // under different rules from the same hazard heard from a neighbour.
      // Returns null for SOS, which never decays (§2.3), and this path never
      // carries one.
      displayLifetime: displayLifetimeFor(claim.type),
    );
    if (stored == null) {
      debugPrint('[mayday.mesh] DEBUG $label: failed to rebuild claim');
      return null;
    }

    await ClaimRepository().insertClaim(stored);

    debugPrint('[mayday.mesh] DEBUG $label raised: id=${stored.id} '
        'origin=${stored.originDeviceId} seq=${stored.originSequence} '
        'trust=${stored.claimTrust.name} hopLimit=${envelope.hopLimit}');
    return stored.id;
  }
}
