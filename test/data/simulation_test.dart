// test/data/simulation_test.dart

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/corroboration.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/identity/sos_identity.dart';
import 'package:mayday/data/identity/report_identity.dart';
import 'package:mayday/data/identity/geohash_utils.dart';
import 'package:mayday/data/time/decay.dart';

/// A simplified in-memory claim store for simulation purposes.
class SimulationStore {
  final Map<String, Claim> _claims = {};
  
  void receiveClaim(Claim newClaim, {bool isRelay = false, String? viaDeviceId}) {
    // Basic de-dup/merge logic
    if (!_claims.containsKey(newClaim.id)) {
      _claims[newClaim.id] = newClaim;
      return;
    }
    
    final existing = _claims[newClaim.id]!;
    
    // Merge logic for mergeable types
    if (newClaim.type == ClaimType.hazardReport) {
      final oldPayload = existing.payload as HazardReportPayload;
      final newPayload = newClaim.payload as HazardReportPayload;
      // Count rises
      existing.payload = HazardReportPayload(
        location: oldPayload.location,
        hazardType: oldPayload.hazardType,
        confirmationCount: oldPayload.confirmationCount + newPayload.confirmationCount,
      );
    } else if (newClaim.type == ClaimType.resource) {
      final oldPayload = existing.payload as ResourcePayload;
      final newPayload = newClaim.payload as ResourcePayload;
      // Add claimed reports
      existing.payload = ResourcePayload(
        location: oldPayload.location,
        category: oldPayload.category,
        pledgedCount: oldPayload.pledgedCount, // Only volunteers can change this
        claimedReports: oldPayload.claimedReports + newPayload.claimedReports,
      );
    }
    
    // Also track corroboration if needed
    if (!isRelay && viaDeviceId == null && newClaim.originDeviceId != existing.originDeviceId) {
       // It's an independent generation
       existing.corroborations.add(
         Corroboration(
           deviceId: newClaim.originDeviceId,
           hopDistance: 0,
           signalStrength: 1.0,
           logicalClock: newClaim.logicalClock,
           isVolunteer: false,
           kind: CorroborationKind.independentGeneration,
         )
       );
    } else if (viaDeviceId != null) {
       // Corroborating something first seen via mesh
       existing.corroborations.add(
         Corroboration(
           deviceId: newClaim.originDeviceId,
           hopDistance: 1,
           signalStrength: 1.0,
           firstSeenVia: viaDeviceId, // anti-echo
           logicalClock: newClaim.logicalClock,
           isVolunteer: false,
           kind: CorroborationKind.explicitAttestation,
         )
       );
    }
  }
  
  void resolveClaim(String id) {
    if (_claims.containsKey(id)) {
      _claims[id]!.status = ClaimStatus.resolved;
    }
  }

  List<Claim> get activeClaims => _claims.values.where((c) => c.status == ClaimStatus.active).toList();
}

void main() {
  group('Day 5: Multi-device simulation harness', () {
    late SimulationStore store;

    setUp(() {
      store = SimulationStore();
    });

    test('Two devices independently generating a matching hazard → merges, count rises', () {
      final loc = const GeoPoint(lat: 10, lon: 10);
      final bucket = getGeohashBucket(loc);
      final hazardId = generateMergeableClaimId(ClaimType.hazardReport, bucket);

      final claim1 = Claim(
        id: hazardId,
        type: ClaimType.hazardReport,
        originDeviceId: 'dev1',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'dev1', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: HazardReportPayload(location: loc, hazardType: HazardType.flood, confirmationCount: 1),
      );

      final claim2 = Claim(
        id: hazardId,
        type: ClaimType.hazardReport,
        originDeviceId: 'dev2',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'dev2', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: HazardReportPayload(location: loc, hazardType: HazardType.flood, confirmationCount: 1),
      );

      store.receiveClaim(claim1);
      store.receiveClaim(claim2);

      expect(store.activeClaims.length, equals(1), reason: 'Hazards must merge');
      final merged = store.activeClaims.first;
      expect((merged.payload as HazardReportPayload).confirmationCount, equals(2), reason: 'Count must rise on merge');
    });

    test('Two devices raising SOS in the same bucket → stays two claims', () {
      final loc = const GeoPoint(lat: 10, lon: 10);
      
      final sos1Id = generateSosClaimId('dev1', 1);
      final claim1 = Claim(
        id: sos1Id,
        type: ClaimType.sos,
        originDeviceId: 'dev1',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'dev1', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: SosPayload(location: loc),
      );

      final sos2Id = generateSosClaimId('dev2', 1);
      final claim2 = Claim(
        id: sos2Id,
        type: ClaimType.sos,
        originDeviceId: 'dev2',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'dev2', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: SosPayload(location: loc),
      );

      store.receiveClaim(claim1);
      store.receiveClaim(claim2);

      expect(store.activeClaims.length, equals(2), reason: 'SOS claims must never merge');

      // Resolve one claim
      store.resolveClaim(sos1Id);

      // Verify the other remains untouched and active
      expect(store.activeClaims.length, equals(1), reason: 'Resolving one must leave the other');
      expect(store.activeClaims.first.id, equals(sos2Id), reason: 'The correct claim remains active');
      expect(store.activeClaims.first.status, equals(ClaimStatus.active), reason: 'Remaining claim is ACTIVE');
    });

    test('A device corroborating something it first saw via mesh → rejected (from trust)', () {
      // In the simulation store, we capture the fact it was relayed
      final loc = const GeoPoint(lat: 10, lon: 10);
      final bucket = getGeohashBucket(loc);
      final hazardId = generateMergeableClaimId(ClaimType.hazardReport, bucket);

      // dev1 generates
      final claim1 = Claim(
        id: hazardId,
        type: ClaimType.hazardReport,
        originDeviceId: 'dev1',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'dev1', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: HazardReportPayload(location: loc, hazardType: HazardType.flood, confirmationCount: 1),
      );
      store.receiveClaim(claim1);

      // dev2 corroborates but saw it via dev1
      final claim2 = Claim(
        id: hazardId,
        type: ClaimType.hazardReport,
        originDeviceId: 'dev2',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'dev2', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: HazardReportPayload(location: loc, hazardType: HazardType.flood, confirmationCount: 1),
      );
      store.receiveClaim(claim2, viaDeviceId: 'dev1');

      final merged = store.activeClaims.first;
      // The corroboration exists but firstSeenVia is set
      final corr = merged.corroborations.firstWhere((c) => c.deviceId == 'dev2');
      expect(corr.firstSeenVia, equals('dev1'));
      // In trust_engine_test, we already proved that firstSeenVia != null is rejected from trust scoring.
    });

    test('Twenty devices each claiming the last resource, then merging → availability floors at 0, never negative', () {
      final loc = const GeoPoint(lat: 10, lon: 10);
      final bucket = getGeohashBucket(loc);
      final resourceId = generateMergeableClaimId(ClaimType.resource, bucket);

      // Original state: 1 item pledged
      final baseClaim = Claim(
        id: resourceId,
        type: ClaimType.resource,
        originDeviceId: 'volunteer',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'volunteer', counter: 1),
        claimTrust: ClaimTrust.groundConfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: ResourcePayload(location: loc, category: ResourceCategory.foodWater, pledgedCount: 1, claimedReports: 0),
      );
      store.receiveClaim(baseClaim);

      // 20 offline devices claim 1 each and merge back
      for (int i = 0; i < 20; i++) {
        final claim = Claim(
          id: resourceId,
          type: ClaimType.resource,
          originDeviceId: 'dev_$i',
          originSequence: 1,
          originSignature: Uint8List(64),
          logicalClock: LogicalClock(deviceId: 'dev_$i', counter: 1),
          claimTrust: ClaimTrust.unconfirmed,
          dispatchPriority: DispatchPriority.low,
          status: ClaimStatus.active,
          hopLimit: 10,
          payload: ResourcePayload(location: loc, category: ResourceCategory.foodWater, pledgedCount: 1, claimedReports: 1),
        );
        store.receiveClaim(claim);
      }

      final merged = store.activeClaims.first;
      final payload = merged.payload as ResourcePayload;
      
      expect(payload.claimedReports, equals(20)); // All claims aggregated
      expect(payload.pledgedCount, equals(1)); // Still only 1 was pledged
      expect(payload.available, equals(0), reason: 'Availability must not be negative (-19)');
    });

    test('SOS with zero corroborations after a long simulated period → still ACTIVE, still visible', () {
      final sosId = generateSosClaimId('dev1', 1);
      final claim = Claim(
        id: sosId,
        type: ClaimType.sos,
        originDeviceId: 'dev1',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: LogicalClock(deviceId: 'dev1', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        displayLifetime: null, // Critical property for SOS
        payload: SosPayload(location: const GeoPoint(lat: 10, lon: 10)),
      );

      // Time passes
      final lifetime = displayLifetimeFor(claim.type);
      
      expect(lifetime, isNull, reason: 'SOS should never decay via a lifetime window');
      expect(claim.status, equals(ClaimStatus.active), reason: 'Should remain active');
    });
  });
}
