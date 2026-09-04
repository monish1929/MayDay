import 'dart:typed_data';

import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/identity/sos_identity.dart';
import 'package:mayday/data/identity/report_identity.dart';
import 'package:mayday/data/identity/geohash_utils.dart';
import 'package:mayday/data/identity/sequence_counter.dart';
import 'package:mayday/data/time/device_clock.dart';

class ClaimFactory {
  /// Provisional until Phase 0 lands real hop-range data.
  ///
  /// `PERSON_A.md` carries this as an open question and says not to pick a
  /// number before the measurements exist. Named rather than inlined so the
  /// eventual real value is a one-line change with an obvious search term —
  /// and so it can never be mistaken for `displayLifetime`, which is a
  /// different quantity entirely (§7).
  static const int provisionalHopLimit = 10;

  /// Assembles a real Claim: routes to the correct id rule for the payload
  /// type, takes a sequence number for identity, and stamps a Lamport clock
  /// for ordering. Those last two are deliberately different counters — see
  /// [DeviceClock].
  ///
  /// The returned claim is unsigned (`originSignature` is empty). The caller
  /// signs `toSignedCoreCbor()` and fills it in before the claim goes
  /// anywhere — an unsigned claim must never reach the store or the wire (§5).
  static Future<Claim> createClaim({
    required ClaimPayload payload,
    required String originDeviceId,
  }) async {
    final ClaimType type = _determineType(payload);
    final int seq = await SequenceCounter.getNextSequence();
    final LogicalClock logicalClock =
        await DeviceClock(originDeviceId).tickForSend();

    // Two separate id rules, never one function with a branch inside — §2.1.
    final String id;
    if (type == ClaimType.sos || type == ClaimType.sosProxy) {
      id = generateSosClaimId(originDeviceId, seq);
    } else {
      id = generateMergeableClaimId(type, getGeohashBucket(payload.location));
    }

    return Claim(
      id: id,
      type: type,
      originDeviceId: originDeviceId,
      originSequence: seq,
      originSignature: Uint8List(0),
      logicalClock: logicalClock,
      claimTrust: ClaimTrust.unconfirmed,
      dispatchPriority: DispatchPriority.low,
      status: ClaimStatus.active,
      hopLimit: provisionalHopLimit,
      createdAtLogical: logicalClock,
      payload: payload,
    );
  }

  static ClaimType _determineType(ClaimPayload payload) => switch (payload) {
        SosPayload() => ClaimType.sos,
        SosProxyPayload() => ClaimType.sosProxy,
        HazardReportPayload() => ClaimType.hazardReport,
        ResourcePayload() => ClaimType.resource,
      };
}
