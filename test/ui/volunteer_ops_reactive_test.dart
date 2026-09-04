// ignore_for_file: avoid_print
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/ui/models/claim_display_helpers.dart';
import 'package:mayday/ui/screens/volunteer_ops_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
  });

  group('Week 2 Day 3: VolunteerOpsScreen Reactive Binding & Sorting', () {
    test('compareRescueClaims sorts by dispatchPriority, claimTrust, and logicalClock', () {
      final claimLow = Claim(
        id: 'c-low',
        type: ClaimType.sos,
        originDeviceId: 'dev-1',
        originSequence: 1,
        logicalClock: const LogicalClock(deviceId: 'dev-1', counter: 10),
        originSignature: Uint8List(0),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: const SosPayload(location: GeoPoint(lat: 12.97, lon: 77.59)),
      );

      final claimSeen = Claim(
        id: 'c-seen',
        type: ClaimType.sos,
        originDeviceId: 'dev-2',
        originSequence: 1,
        logicalClock: const LogicalClock(deviceId: 'dev-2', counter: 5),
        originSignature: Uint8List(0),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.seenByVolunteer,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: const SosPayload(location: GeoPoint(lat: 12.97, lon: 77.59)),
      );

      final claimEnRoute = Claim(
        id: 'c-enroute',
        type: ClaimType.sos,
        originDeviceId: 'dev-3',
        originSequence: 1,
        logicalClock: const LogicalClock(deviceId: 'dev-3', counter: 8),
        originSignature: Uint8List(0),
        claimTrust: ClaimTrust.corroborated,
        dispatchPriority: DispatchPriority.enRoute,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: const SosPayload(location: GeoPoint(lat: 12.97, lon: 77.59)),
      );

      final claimCorroboratedLow = Claim(
        id: 'c-corrob-low',
        type: ClaimType.sos,
        originDeviceId: 'dev-4',
        originSequence: 1,
        logicalClock: const LogicalClock(deviceId: 'dev-4', counter: 2),
        originSignature: Uint8List(0),
        claimTrust: ClaimTrust.corroborated,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: const SosPayload(location: GeoPoint(lat: 12.97, lon: 77.59)),
      );

      final claims = [claimLow, claimEnRoute, claimCorroboratedLow, claimSeen];
      claims.sort(ClaimDisplayHelpers.compareRescueClaims);

      // Expected order:
      // 1. claimEnRoute (enRoute)
      // 2. claimSeen (seenByVolunteer)
      // 3. claimCorroboratedLow (low, but corroborated)
      // 4. claimLow (low, unconfirmed)
      expect(claims[0].id, 'c-enroute');
      expect(claims[1].id, 'c-seen');
      expect(claims[2].id, 'c-corrob-low');
      expect(claims[3].id, 'c-low');
    });

    test('compareHazardClaims sorts by confirmationCount descending', () {
      final hazard1 = Claim(
        id: 'h-1',
        type: ClaimType.hazardReport,
        originDeviceId: 'dev-1',
        originSequence: 1,
        logicalClock: const LogicalClock(deviceId: 'dev-1', counter: 1),
        originSignature: Uint8List(0),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: const HazardReportPayload(
          location: GeoPoint(lat: 12.97, lon: 77.59),
          hazardType: HazardType.flood,
          confirmationCount: 1,
        ),
      );

      final hazard5 = Claim(
        id: 'h-5',
        type: ClaimType.hazardReport,
        originDeviceId: 'dev-2',
        originSequence: 1,
        logicalClock: const LogicalClock(deviceId: 'dev-2', counter: 2),
        originSignature: Uint8List(0),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: const HazardReportPayload(
          location: GeoPoint(lat: 12.97, lon: 77.59),
          hazardType: HazardType.flood,
          confirmationCount: 5,
        ),
      );

      final hazard3 = Claim(
        id: 'h-3',
        type: ClaimType.hazardReport,
        originDeviceId: 'dev-3',
        originSequence: 1,
        logicalClock: const LogicalClock(deviceId: 'dev-3', counter: 3),
        originSignature: Uint8List(0),
        claimTrust: ClaimTrust.corroborated,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        payload: const HazardReportPayload(
          location: GeoPoint(lat: 12.97, lon: 77.59),
          hazardType: HazardType.flood,
          confirmationCount: 3,
        ),
      );

      final hazards = [hazard1, hazard3, hazard5];
      hazards.sort(ClaimDisplayHelpers.compareHazardClaims);

      expect(hazards[0].id, 'h-5');
      expect(hazards[1].id, 'h-3');
      expect(hazards[2].id, 'h-1');
    });

    test('Resource availability is computed dynamically and clamped at zero', () {
      const normalResource = ResourcePayload(
        location: GeoPoint(lat: 12.97, lon: 77.59),
        category: ResourceCategory.foodWater,
        pledgedCount: 100,
        claimedReports: 25,
      );
      expect(normalResource.available, 75);

      const depletedResource = ResourcePayload(
        location: GeoPoint(lat: 12.97, lon: 77.59),
        category: ResourceCategory.medical,
        pledgedCount: 50,
        claimedReports: 60, // Over-claimed
      );
      expect(depletedResource.available, 0); // Clamped at 0
    });

    testWidgets('VolunteerOpsScreen stream reactivity updates tab counts and list live', (tester) async {
      final repo = ClaimRepository();

      await tester.runAsync(() async {
        final sos1 = await ClaimFactory.createClaim(
          originDeviceId: 'dev-ops-1',
          payload: const SosPayload(location: GeoPoint(lat: 12.97, lon: 77.59)),
        );
        await repo.insertClaim(sos1);
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: VolunteerOpsScreen(),
        ),
      );

      // Drain initial stream snapshot
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      // Verify initial tab count is 1 for Rescue
      expect(find.text('Rescue (1)'), findsOneWidget);
      expect(find.text('Reports (0)'), findsOneWidget);
      expect(find.text('Resources (0)'), findsOneWidget);

      // Insert Hazard and Resource claims dynamically
      await tester.runAsync(() async {
        final hazard = await ClaimFactory.createClaim(
          originDeviceId: 'dev-ops-2',
          payload: const HazardReportPayload(
            location: GeoPoint(lat: 12.98, lon: 77.60),
            hazardType: HazardType.structuralDamage,
            confirmationCount: 3,
          ),
        );
        final resource = await ClaimFactory.createClaim(
          originDeviceId: 'dev-ops-3',
          payload: const ResourcePayload(
            location: GeoPoint(lat: 12.99, lon: 77.61),
            category: ResourceCategory.foodWater,
            pledgedCount: 50,
            claimedReports: 10,
          ),
        );
        await repo.insertClaim(hazard);
        await repo.insertClaim(resource);
      });

      // Allow stream event to propagate and rebuild UI
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump();

      // Tab counts must have updated live to (1), (1), (1) without navigating away
      expect(find.text('Rescue (1)'), findsOneWidget);
      expect(find.text('Reports (1)'), findsOneWidget);
      expect(find.text('Resources (1)'), findsOneWidget);

      // Cleanly unmount
      await tester.pumpWidget(const SizedBox());
    });
  });
}
