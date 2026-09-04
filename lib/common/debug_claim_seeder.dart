import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';

/// Debug-only utility to bulk-seed synthetic claims into the real local SQLite database.
///
/// Gated to kDebugMode only. Never runs in release builds.
class DebugClaimSeeder {
  /// Seeds synthetic claims into the active SQLite database for testing scale and rendering.
  static Future<int> seedSyntheticClaims({
    int count = 120,
    double baseLat = 12.9716,
    double baseLon = 77.5946,
    double radiusDegrees = 0.15, // ~10-15km radius around base
  }) async {
    if (!kDebugMode) {
      debugPrint('[DebugClaimSeeder] Refusing to seed claims: not in debug mode.');
      return 0;
    }

    final repo = ClaimRepository();
    final random = Random();

    for (int i = 0; i < count; i++) {
      final offsetLat = (random.nextDouble() - 0.5) * radiusDegrees;
      final offsetLon = (random.nextDouble() - 0.5) * radiusDegrees;
      final loc = GeoPoint(lat: baseLat + offsetLat, lon: baseLon + offsetLon);

      final ClaimPayload payload;
      final int typeIndex = i % 4;
      if (typeIndex == 0) {
        payload = SosPayload(
          location: loc,
          headcount: i % 2 == 0 ? null : HeadcountBucket.twoToFive,
        );
      } else if (typeIndex == 1) {
        payload = SosProxyPayload(
          location: loc,
          reporterDeviceId: 'dev-bulk-reporter',
          headcount: HeadcountBucket.sixToFifteen,
          proxyNote: 'Group trapped near water tank $i',
        );
      } else if (typeIndex == 2) {
        payload = HazardReportPayload(
          location: loc,
          hazardType: HazardType.values[i % HazardType.values.length],
          confirmationCount: (i % 5) + 1,
          note: 'Flood alert #$i',
        );
      } else {
        payload = ResourcePayload(
          location: loc,
          category: ResourceCategory.values[i % ResourceCategory.values.length],
          pledgedCount: (i + 1) * 5,
          claimedReports: 0,
        );
      }

      final claim = await ClaimFactory.createClaim(
        originDeviceId: 'dev-node-$i',
        payload: payload,
      );

      // Distribute realistic trust levels
      if (i % 3 == 0) {
        claim.claimTrust = ClaimTrust.groundConfirmed;
      } else if (i % 2 == 0) {
        claim.claimTrust = ClaimTrust.corroborated;
      } else {
        claim.claimTrust = ClaimTrust.unconfirmed;
      }

      await repo.insertClaim(claim);
    }

    debugPrint('[DebugClaimSeeder] Successfully seeded $count claims into SQLite.');
    return count;
  }
}
