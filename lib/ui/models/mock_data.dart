import 'enums.dart';
import 'geo_point.dart';
import 'logical_clock.dart';
import 'corroboration.dart';
import 'claim_payloads.dart';
import 'mock_claim.dart';

/// Pre-built mock claims for Week 1 UI development.
///
/// These exist purely so C can build and test screens without waiting on B's
/// data layer. They will be replaced by real SQLite queries in Week 2.
///
/// Mock data deliberately includes edge cases the UI must handle:
/// - An old unresolved SOS (should render with MORE urgency, not less)
/// - Two SOS in the same area (must be two pins, not one — CLAUDE.md §2.1)
/// - A Proxy SOS (distinct icon — PERSON_C.md §8)
/// - All three trust tiers
/// - All three dispatch priorities
class MockData {
  static List<MockClaim> generateMockClaims() {
    final now = DateTime.now();
    return [
      // ─── SOS claims ───────────────────────────────────────────────
      // Individual SOS — UNCONFIRMED, recent (10 min ago — below aging threshold)
      MockClaim(
        id: 'sos-001',
        type: ClaimType.sos,
        originDeviceId: 'device-aaa',
        originSignature: 'mock-sig-001',
        logicalClock: const LogicalClock(deviceId: 'device-aaa', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        corroborations: [],
        status: ClaimStatus.active,
        hopLimit: 10,
        // SOS never decays — CLAUDE.md §2.3. displayLifetime is NULL.
        displayLifetime: null,
        mockCreatedAt: now.subtract(const Duration(minutes: 10)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-aaa', counter: 1),
        payload: SosPayload(
          location: const GeoPoint(lat: 12.9716, lon: 77.5946),
        ),
      ),

      // Group SOS — CORROBORATED, volunteer en route (2 hours ago — aging tier 1)
      MockClaim(
        id: 'sos-002',
        type: ClaimType.sos,
        originDeviceId: 'device-bbb',
        originSignature: 'mock-sig-002',
        logicalClock: const LogicalClock(deviceId: 'device-bbb', counter: 3),
        claimTrust: ClaimTrust.corroborated,
        dispatchPriority: DispatchPriority.enRoute,
        corroborations: [
          Corroboration(
            deviceId: 'device-ccc',
            hopDistance: 1,
            signalStrength: -65.0,
            firstSeenVia: null, // independent observation
            logicalClock:
                const LogicalClock(deviceId: 'device-ccc', counter: 5),
            isVolunteer: false,
            kind: CorroborationKind.independentGeneration,
          ),
        ],
        status: ClaimStatus.active,
        hopLimit: 7,
        displayLifetime: null,
        mockCreatedAt: now.subtract(const Duration(hours: 2)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-bbb', counter: 3),
        payload: SosPayload(
          location: const GeoPoint(lat: 12.9720, lon: 77.5950),
          headcount: HeadcountBucket.sixToFifteen,
        ),
      ),

      // Old unresolved SOS — still UNCONFIRMED, still ACTIVE (6+ hours ago — aging tier 3).
      // This must render with MORE visual urgency, not less — CLAUDE.md §2.3.
      // An aging unresolved SOS means someone has been waiting longer for help.
      MockClaim(
        id: 'sos-003',
        type: ClaimType.sos,
        originDeviceId: 'device-ddd',
        originSignature: 'mock-sig-003',
        logicalClock: const LogicalClock(deviceId: 'device-ddd', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        corroborations: [],
        status: ClaimStatus.active,
        hopLimit: 3,
        displayLifetime: null,
        mockCreatedAt: now.subtract(const Duration(hours: 6, minutes: 30)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-ddd', counter: 1),
        payload: SosPayload(
          location: const GeoPoint(lat: 12.9800, lon: 77.5800),
        ),
      ),

      // ─── Proxy SOS ────────────────────────────────────────────────
      // Raised on behalf of a neighbour whose phone is dead (45 min ago — below aging threshold).
      // Must show with a distinct icon — PERSON_C.md §8.
      MockClaim(
        id: 'sos-proxy-001',
        type: ClaimType.sosProxy,
        originDeviceId: 'device-eee',
        originSignature: 'mock-sig-004',
        logicalClock: const LogicalClock(deviceId: 'device-eee', counter: 2),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.seenByVolunteer,
        corroborations: [],
        status: ClaimStatus.active,
        hopLimit: 8,
        displayLifetime: null,
        mockCreatedAt: now.subtract(const Duration(minutes: 45)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-eee', counter: 2),
        payload: SosProxyPayload(
          location: const GeoPoint(lat: 12.9650, lon: 77.6000),
          reporterDeviceId: 'device-eee',
          headcount: HeadcountBucket.twoToFive,
          proxyNote: 'Family of 3 trapped on second floor',
        ),
      ),

      // ─── Hazard reports ───────────────────────────────────────────
      // Flood — CORROBORATED, multiple reports merged
      MockClaim(
        id: 'hazard-001',
        type: ClaimType.hazardReport,
        originDeviceId: 'device-fff',
        originSignature: 'mock-sig-005',
        logicalClock: const LogicalClock(deviceId: 'device-fff', counter: 4),
        claimTrust: ClaimTrust.corroborated,
        dispatchPriority: DispatchPriority.low,
        corroborations: [
          Corroboration(
            deviceId: 'device-ggg',
            hopDistance: 2,
            signalStrength: -72.0,
            firstSeenVia: null,
            logicalClock:
                const LogicalClock(deviceId: 'device-ggg', counter: 3),
            isVolunteer: false,
            kind: CorroborationKind.independentGeneration,
          ),
        ],
        status: ClaimStatus.active,
        hopLimit: 5,
        displayLifetime: const Duration(hours: 48),
        mockCreatedAt: now.subtract(const Duration(hours: 3, minutes: 15)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-fff', counter: 4),
        payload: HazardReportPayload(
          location: const GeoPoint(lat: 12.9600, lon: 77.5900),
          hazardType: HazardType.flood,
          confirmationCount: 12,
        ),
      ),

      // Road block — GROUND_CONFIRMED by volunteer
      MockClaim(
        id: 'hazard-002',
        type: ClaimType.hazardReport,
        originDeviceId: 'device-hhh',
        originSignature: 'mock-sig-006',
        logicalClock: const LogicalClock(deviceId: 'device-hhh', counter: 2),
        claimTrust: ClaimTrust.groundConfirmed,
        dispatchPriority: DispatchPriority.seenByVolunteer,
        corroborations: [],
        status: ClaimStatus.active,
        hopLimit: 4,
        displayLifetime: const Duration(hours: 48),
        mockCreatedAt: now.subtract(const Duration(hours: 1, minutes: 40)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-hhh', counter: 2),
        payload: HazardReportPayload(
          location: const GeoPoint(lat: 12.9550, lon: 77.5850),
          hazardType: HazardType.roadBlock,
          confirmationCount: 3,
        ),
      ),

      // ─── Resources ────────────────────────────────────────────────
      // Food & Water
      MockClaim(
        id: 'resource-001',
        type: ClaimType.resource,
        originDeviceId: 'device-iii',
        originSignature: 'mock-sig-007',
        logicalClock: const LogicalClock(deviceId: 'device-iii', counter: 5),
        claimTrust: ClaimTrust.corroborated,
        dispatchPriority: DispatchPriority.low,
        corroborations: [],
        status: ClaimStatus.active,
        hopLimit: 5,
        displayLifetime: const Duration(hours: 12),
        mockCreatedAt: now.subtract(const Duration(hours: 4)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-iii', counter: 5),
        payload: ResourcePayload(
          location: const GeoPoint(lat: 12.9700, lon: 77.5870),
          category: ResourceCategory.foodWater,
          pledgedCount: 20,
          claimedReports: 14,
        ),
      ),

      // Shelter — UNCONFIRMED
      MockClaim(
        id: 'resource-002',
        type: ClaimType.resource,
        originDeviceId: 'device-jjj',
        originSignature: 'mock-sig-008',
        logicalClock: const LogicalClock(deviceId: 'device-jjj', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        corroborations: [],
        status: ClaimStatus.active,
        hopLimit: 6,
        displayLifetime: const Duration(hours: 12),
        mockCreatedAt: now.subtract(const Duration(hours: 1, minutes: 20)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-jjj', counter: 1),
        payload: ResourcePayload(
          location: const GeoPoint(lat: 12.9750, lon: 77.5920),
          category: ResourceCategory.shelter,
          pledgedCount: 5,
          claimedReports: 0,
        ),
      ),

      // Medical — GROUND_CONFIRMED
      MockClaim(
        id: 'resource-003',
        type: ClaimType.resource,
        originDeviceId: 'device-kkk',
        originSignature: 'mock-sig-009',
        logicalClock: const LogicalClock(deviceId: 'device-kkk', counter: 8),
        claimTrust: ClaimTrust.groundConfirmed,
        dispatchPriority: DispatchPriority.seenByVolunteer,
        corroborations: [],
        status: ClaimStatus.active,
        hopLimit: 4,
        displayLifetime: const Duration(hours: 12),
        mockCreatedAt: now.subtract(const Duration(minutes: 30)),
        createdAtLogical:
            const LogicalClock(deviceId: 'device-kkk', counter: 8),
        payload: ResourcePayload(
          location: const GeoPoint(lat: 12.9680, lon: 77.5960),
          category: ResourceCategory.medical,
          pledgedCount: 10,
          claimedReports: 8,
        ),
      ),
    ];
  }
}
