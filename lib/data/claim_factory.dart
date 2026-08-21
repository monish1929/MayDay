import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/identity/sos_identity.dart';
import 'package:mayday/data/identity/report_identity.dart';
import 'package:mayday/data/identity/geohash_utils.dart';
import 'package:mayday/data/identity/sequence_counter.dart';
import 'package:mayday/data/models/geo_point.dart';

class ClaimFactory {
  /// Assembles a real Claim by generating its ID based on the payload type,
  /// incrementing the sequence counter, and structuring the mandatory fields.
  static Future<Claim> createClaim({
    required ClaimPayload payload,
    required String originDeviceId,
  }) async {
    final ClaimType type = _determineType(payload);
    final int seq = await SequenceCounter.getNextSequence();
    
    String id;
    if (type == ClaimType.sos || type == ClaimType.sosProxy) {
      id = generateSosClaimId(originDeviceId, seq);
    } else {
      // Must be HazardReportPayload or ResourcePayload which have location
      final location = _extractLocation(payload);
      final geohashBucket = getGeohashBucket(location);
      id = generateMergeableClaimId(type, geohashBucket);
    }

    final logicalClock = LogicalClock(deviceId: originDeviceId, counter: seq);

    return Claim(
      id: id,
      type: type,
      originDeviceId: originDeviceId,
      // The originSignature is typically computed and set immediately after this factory call.
      // We initialize it empty here.
      originSignature: '', 
      logicalClock: logicalClock,
      claimTrust: ClaimTrust.unconfirmed,
      dispatchPriority: DispatchPriority.low,
      status: ClaimStatus.active,
      hopLimit: 10, // Default hop limit, TBD based on Phase 0
      createdAtLogical: logicalClock,
      payload: payload,
    );
  }

  static ClaimType _determineType(ClaimPayload payload) {
    if (payload is SosPayload) return ClaimType.sos;
    if (payload is SosProxyPayload) return ClaimType.sosProxy;
    if (payload is HazardReportPayload) return ClaimType.hazardReport;
    if (payload is ResourcePayload) return ClaimType.resource;
    throw ArgumentError('Unknown payload type');
  }

  static GeoPoint _extractLocation(ClaimPayload payload) {
    if (payload is SosPayload) return payload.location;
    if (payload is SosProxyPayload) return payload.location;
    if (payload is HazardReportPayload) return payload.location;
    if (payload is ResourcePayload) return payload.location;
    throw ArgumentError('Payload has no location');
  }
}
