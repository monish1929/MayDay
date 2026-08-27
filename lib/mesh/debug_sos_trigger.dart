// lib/mesh/debug_sos_trigger.dart


import 'package:cbor/cbor.dart';
import 'package:flutter/foundation.dart';

import '../data/claim_factory.dart';
import '../data/database/claim_repository.dart';
import '../data/models/claim.dart';
import '../data/models/claim_payload.dart';
import '../data/models/geo_point.dart';
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

  /// Builds, signs, stores and queues one SOS.
  ///
  /// Returns the claim id so it can be matched against the other phone's store.
  static Future<String?> raise(MeshNode node) async {
    if (!enabled) return null;

    final claim = await ClaimFactory.createClaim(
      payload: const SosPayload(location: testLocation),
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
      // NULL, not a large number. SOS never decays — §2.3. A person trapped
      // alone is UNCONFIRMED precisely because nobody is nearby to corroborate
      // them, which is exactly why their claim must not age out.
      displayLifetime: null,
    );
    if (stored == null) {
      debugPrint('[mayday.mesh] DEBUG SOS: failed to rebuild claim');
      return null;
    }

    await ClaimRepository().insertClaim(stored);

    debugPrint('[mayday.mesh] DEBUG SOS raised: id=${stored.id} '
        'origin=${stored.originDeviceId} seq=${stored.originSequence} '
        'trust=${stored.claimTrust.name} hopLimit=${envelope.hopLimit}');
    return stored.id;
  }
}
