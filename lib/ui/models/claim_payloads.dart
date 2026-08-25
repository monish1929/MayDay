import 'enums.dart';
import 'geo_point.dart';

/// Type-specific payloads — CLAIM_SCHEMA.md §8.
/// Sealed class so every switch is exhaustive.
sealed class ClaimPayload {
  GeoPoint get location;
}

/// SOS payload — self-raised — CLAIM_SCHEMA.md §8.
class SosPayload extends ClaimPayload {
  @override
  final GeoPoint location;

  /// 2-5 | 6-15 | 15+, for group SOS. Null for individual SOS.
  final HeadcountBucket? headcount;

  SosPayload({required this.location, this.headcount});
}

/// Proxy SOS — raised on behalf of someone else — CLAIM_SCHEMA.md §8.
/// Reporter marks the location on the map; reporter details may be less
/// reliable than first-hand (shown with a distinct icon — PERSON_C.md §8).
class SosProxyPayload extends ClaimPayload {
  @override
  final GeoPoint location;
  final HeadcountBucket? headcount;

  /// Distinct from originDeviceId if relayed on their behalf.
  final String reporterDeviceId;

  /// Optional note, capped at 80 characters — CLAIM_SCHEMA.md §9.2.
  final String? proxyNote;

  SosProxyPayload({
    required this.location,
    required this.reporterDeviceId,
    this.headcount,
    this.proxyNote,
  }) : assert(proxyNote == null || proxyNote.length <= 80,
            'Proxy note capped at 80 chars — CLAIM_SCHEMA.md §9.2');
}

/// Hazard report — CLAIM_SCHEMA.md §8.
/// Merges with other reports in the same geohash bucket → confirmation count rises.
class HazardReportPayload extends ClaimPayload {
  @override
  final GeoPoint location;
  final HazardType hazardType;

  /// Rises as independent reports merge in — CLAIM_SCHEMA.md §2.
  final int confirmationCount;

  /// Optional note, capped at 80 characters — CLAIM_SCHEMA.md §9.2.
  final String? note;

  HazardReportPayload({
    required this.location,
    required this.hazardType,
    this.confirmationCount = 1,
    this.note,
  }) : assert(note == null || note.length <= 80,
            'Note capped at 80 chars — CLAIM_SCHEMA.md §9.2');
}

/// Resource payload — CLAIM_SCHEMA.md §8 + §8.1.
/// Volunteer-only action (identity-gated — CLAUDE.md §7).
class ResourcePayload extends ClaimPayload {
  @override
  final GeoPoint location;

  /// Canonical four: foodWater | shelter | medical | equipment.
  final ResourceCategory category;

  /// Volunteer-written only, add-only, authoritative — CLAIM_SCHEMA.md §8.1.
  final int pledgedCount;

  /// Any user, rate-limited, add-only, soft signal — CLAIM_SCHEMA.md §8.1.
  final int claimedReports;

  ResourcePayload({
    required this.location,
    required this.category,
    this.pledgedCount = 0,
    this.claimedReports = 0,
  });

  /// Availability is computed, never stored — CLAUDE.md §7, CLAIM_SCHEMA.md §8.1.
  /// Never cache this in widget state and mutate it locally — that's how it
  /// drifts from truth.
  int get available {
    final val = pledgedCount - claimedReports;
    return val < 0 ? 0 : val;
  }
}
