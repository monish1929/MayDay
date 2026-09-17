import 'dart:math';
import 'package:cbor/cbor.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/identity/geohash_utils.dart';
import 'package:mayday/data/identity/sos_identity.dart';
import 'package:mayday/data/identity/report_identity.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';

/// Debug-only utility to bulk-seed synthetic claims into the real local SQLite database.
///
/// Gated to kDebugMode only. Never runs in release builds.
class DebugClaimSeeder {
  /// Seeds synthetic claims into the active SQLite database for testing scale and rendering.
  static Future<int> seedSyntheticClaims({
    int count = 120,
    double baseLat = 11.75,
    double baseLon = 76.075,
    double radiusDegrees = 0.15, // ~10-15km radius around base
  }) async {
    if (!kDebugMode) {
      debugPrint('[DebugClaimSeeder] Refusing to seed claims: not in debug mode.');
      return 0;
    }

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

      ClaimType type;
      if (typeIndex == 0) {
        type = ClaimType.sos;
      } else if (typeIndex == 1) {
        type = ClaimType.sosProxy;
      } else if (typeIndex == 2) {
        type = ClaimType.hazardReport;
      } else {
        type = ClaimType.resource;
      }

      final originDeviceId = 'dev-node-$i';
      final int seq = i + 1; // mock sequence
      
      String id;
      if (type == ClaimType.sos || type == ClaimType.sosProxy) {
        id = generateSosClaimId(originDeviceId, seq);
      } else {
        id = generateMergeableClaimId(type, getGeohashBucket(loc));
      }

      // Distribute realistic trust levels
      ClaimTrust trust;
      if (i % 3 == 0) {
        trust = ClaimTrust.groundConfirmed;
      } else if (i % 2 == 0) {
        trust = ClaimTrust.corroborated;
      } else {
        trust = ClaimTrust.unconfirmed;
      }

      // DEBUG ONLY: bypasses ClaimFactory/insertClaim's signature guard since 
      // synthetic seed data has no real origin device to sign it. Never use 
      // this pattern for real claim creation.
      final db = await DatabaseHelper.instance.database;
      final payloadCbor = Uint8List.fromList(cbor.encode(payload.toCbor()));
      await db.insert(
        'claims',
        {
          'id': id,
          'type': type.index,
          'origin_device_id': originDeviceId,
          'origin_sequence': seq,
          'clock_device_id': originDeviceId,
          'clock_counter': 1,
          'lat': loc.lat,
          'lon': loc.lon,
          'geohash_bucket': getGeohashBucket(loc),
          'origin_signature': Uint8List(0),
          'claim_trust': trust.index,
          'dispatch_priority': DispatchPriority.low.index,
          'status': ClaimStatus.active.index,
          'payload': payloadCbor,
          'hop_limit': ClaimFactory.provisionalHopLimit,
          'created_at_logical_device_id': originDeviceId,
          'created_at_logical_counter': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    debugPrint('[DebugClaimSeeder] Successfully seeded $count claims into SQLite.');
    return count;
  }
}
