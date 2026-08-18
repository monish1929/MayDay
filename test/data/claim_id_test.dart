// test/data/claim_id_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mayday/data/identity/sos_identity.dart';
import 'package:mayday/data/identity/report_identity.dart';
import 'package:mayday/data/identity/geohash_utils.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/enums.dart';

void main() {
  group('Claim Identity Rules (§2)', () {
    test('Two SOS claims, same geohash bucket, same minute, different origin devices do not merge', () {
      // 1. Same location (same geohash bucket)
      const location = GeoPoint(lat: 12.9716, lon: 77.5946);
      final bucket1 = getGeohashBucket(location);
      final bucket2 = getGeohashBucket(location);
      
      expect(bucket1, bucket2, reason: 'Locations are identical, should be same bucket');

      // 2. Different devices, same sequence (e.g., both are the first SOS on their respective devices)
      final deviceA = 'device_A_key_123';
      final deviceB = 'device_B_key_456';
      
      final sequenceA = 1;
      final sequenceB = 1;

      // 3. Generate IDs
      final idA = generateSosClaimId(deviceA, sequenceA);
      final idB = generateSosClaimId(deviceB, sequenceB);

      // 4. Verify IDs are distinct
      expect(idA, isNot(equals(idB)), reason: 'SOS IDs must be distinct even if in same location/time');
      
      // Because the IDs are distinct, they will be stored as two separate records in the SQLite DB
      // and resolving one (via QR which requires the specific SOS ID) will leave the other untouched.
    });

    test('Two Hazard Reports, same geohash bucket, merge into one ID', () {
      const location = GeoPoint(lat: 12.9716, lon: 77.5946);
      final bucket = getGeohashBucket(location);
      
      final id1 = generateMergeableClaimId(ClaimType.hazardReport, bucket);
      final id2 = generateMergeableClaimId(ClaimType.hazardReport, bucket);

      expect(id1, equals(id2), reason: 'Hazards in the same bucket must share an ID to merge');
    });

    test('Two different claim types in the same geohash do not merge', () {
      const location = GeoPoint(lat: 12.9716, lon: 77.5946);
      final bucket = getGeohashBucket(location);
      
      final idHazard = generateMergeableClaimId(ClaimType.hazardReport, bucket);
      final idResource = generateMergeableClaimId(ClaimType.resource, bucket);

      expect(idHazard, isNot(equals(idResource)), reason: 'Different types should not merge');
    });

    test('Attempting to use mergeable function for SOS throws', () {
      const location = GeoPoint(lat: 12.9716, lon: 77.5946);
      final bucket = getGeohashBucket(location);
      
      expect(
        () => generateMergeableClaimId(ClaimType.sos, bucket),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
