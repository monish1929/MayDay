// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/enums.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
  });

  tearDown(() async {
    await DatabaseHelper.instance.close();
  });

  group('Week 2 Day 1: End-to-End Claim Persistence & App Restart', () {
    test('Submitting and persisting all 5 claim types survives app restart', () async {
      final repo = ClaimRepository();
      const testLocation = GeoPoint(lat: 12.9716, lon: 77.5946);

      // 1. Individual SOS
      final individualSosPayload = const SosPayload(
        location: testLocation,
        headcount: null,
      );
      final individualSos = await ClaimFactory.createClaim(
        payload: individualSosPayload,
        originDeviceId: 'device-test-1',
      );
      await repo.insertClaim(individualSos);

      // 2. Group SOS
      final groupSosPayload = const SosPayload(
        location: testLocation,
        headcount: HeadcountBucket.sixToFifteen,
      );
      final groupSos = await ClaimFactory.createClaim(
        payload: groupSosPayload,
        originDeviceId: 'device-test-1',
      );
      await repo.insertClaim(groupSos);

      // 3. Proxy SOS
      final proxySosPayload = const SosProxyPayload(
        location: testLocation,
        reporterDeviceId: 'device-test-1',
        headcount: HeadcountBucket.twoToFive,
        proxyNote: 'Elderly neighbor trapped on ground floor',
      );
      final proxySos = await ClaimFactory.createClaim(
        payload: proxySosPayload,
        originDeviceId: 'device-test-1',
      );
      await repo.insertClaim(proxySos);

      // 4. Hazard Report
      final hazardPayload = const HazardReportPayload(
        location: testLocation,
        hazardType: HazardType.flood,
        confirmationCount: 1,
        note: 'Water 3ft deep across main street',
      );
      final hazard = await ClaimFactory.createClaim(
        payload: hazardPayload,
        originDeviceId: 'device-test-1',
      );
      await repo.insertClaim(hazard);

      // 5. Resource Contribution
      final resourcePayload = const ResourcePayload(
        location: testLocation,
        category: ResourceCategory.foodWater,
        pledgedCount: 50,
        claimedReports: 0,
      );
      final resource = await ClaimFactory.createClaim(
        payload: resourcePayload,
        originDeviceId: 'device-test-1',
      );
      await repo.insertClaim(resource);

      // --- SIMULATE APP RESTART VIA EXPLICIT DATABASE CLOSE & REOPEN ---
      // Force-close the active SQLite connection handle
      await DatabaseHelper.instance.close();

      // Fresh repository query triggers a clean database re-open on the persisted file
      final newRepoInstance = ClaimRepository();
      final activeClaims = await newRepoInstance.getActiveClaims();

      // Confirm all 5 claims are retrieved after restart
      expect(activeClaims.length, 5);
      print('\n=== getActiveClaims() Output after Persistence ===');
      for (final claim in activeClaims) {
        print('----------------------------------------------------');
        print('Claim ID:         ${claim.id}');
        print('Type:             ${claim.type.name}');
        print('Origin Device:    ${claim.originDeviceId}');
        print('Origin Sequence:  ${claim.originSequence}');
        print('Status:           ${claim.status.name}');
        print('Trust:            ${claim.claimTrust.name}');
        print('Priority:         ${claim.dispatchPriority.name}');
        print('Hop Limit:        ${claim.hopLimit}');
        print('Logical Clock:    ${claim.logicalClock}');
        print('Payload:          ${claim.payload.runtimeType}');
        if (claim.payload is SosPayload) {
          final p = claim.payload as SosPayload;
          print('  Location: (${p.location.lat}, ${p.location.lon})');
          print('  Headcount: ${p.headcount?.name ?? "null (Individual)"}');
        } else if (claim.payload is SosProxyPayload) {
          final p = claim.payload as SosProxyPayload;
          print('  Location: (${p.location.lat}, ${p.location.lon})');
          print('  Reporter: ${p.reporterDeviceId}');
          print('  Headcount: ${p.headcount?.name ?? "null"}');
          print('  Proxy Note: "${p.proxyNote}"');
        } else if (claim.payload is HazardReportPayload) {
          final p = claim.payload as HazardReportPayload;
          print('  Location: (${p.location.lat}, ${p.location.lon})');
          print('  Hazard: ${p.hazardType.name}');
          print('  Confirmation Count: ${p.confirmationCount}');
          print('  Note: "${p.note}"');
        } else if (claim.payload is ResourcePayload) {
          final p = claim.payload as ResourcePayload;
          print('  Location: (${p.location.lat}, ${p.location.lon})');
          print('  Category: ${p.category.name}');
          print('  Pledged Count: ${p.pledgedCount}');
          print('  Claimed Reports: ${p.claimedReports}');
          print('  Available: ${p.available}');
        }
      }
      print('====================================================\n');

      // Verify Individual SOS
      final retrievedIndividual = activeClaims.firstWhere((c) => c.id == individualSos.id);
      expect(retrievedIndividual.type, ClaimType.sos);
      expect(retrievedIndividual.payload, isA<SosPayload>());
      expect((retrievedIndividual.payload as SosPayload).headcount, isNull);
      expect(retrievedIndividual.status, ClaimStatus.active);
      expect(retrievedIndividual.originDeviceId, 'device-test-1');

      // Verify Group SOS
      final retrievedGroup = activeClaims.firstWhere((c) => c.id == groupSos.id);
      expect(retrievedGroup.type, ClaimType.sos);
      expect(retrievedGroup.payload, isA<SosPayload>());
      expect((retrievedGroup.payload as SosPayload).headcount, HeadcountBucket.sixToFifteen);

      // Verify Proxy SOS
      final retrievedProxy = activeClaims.firstWhere((c) => c.id == proxySos.id);
      expect(retrievedProxy.type, ClaimType.sosProxy);
      expect(retrievedProxy.payload, isA<SosProxyPayload>());
      final proxyData = retrievedProxy.payload as SosProxyPayload;
      expect(proxyData.reporterDeviceId, 'device-test-1');
      expect(proxyData.headcount, HeadcountBucket.twoToFive);
      expect(proxyData.proxyNote, 'Elderly neighbor trapped on ground floor');

      // Verify Hazard Report
      final retrievedHazard = activeClaims.firstWhere((c) => c.id == hazard.id);
      expect(retrievedHazard.type, ClaimType.hazardReport);
      expect(retrievedHazard.payload, isA<HazardReportPayload>());
      final hazardData = retrievedHazard.payload as HazardReportPayload;
      expect(hazardData.hazardType, HazardType.flood);
      expect(hazardData.confirmationCount, 1);
      expect(hazardData.note, 'Water 3ft deep across main street');

      // Verify Resource
      final retrievedResource = activeClaims.firstWhere((c) => c.id == resource.id);
      expect(retrievedResource.type, ClaimType.resource);
      expect(retrievedResource.payload, isA<ResourcePayload>());
      final resourceData = retrievedResource.payload as ResourcePayload;
      expect(resourceData.category, ResourceCategory.foodWater);
      expect(resourceData.pledgedCount, 50);
      expect(resourceData.claimedReports, 0);
      expect(resourceData.available, 50);
    });

    test('Two SOS claims from same location get distinct IDs (§2 invariant)', () async {
      final repo = ClaimRepository();
      const location = GeoPoint(lat: 12.9716, lon: 77.5946);

      final sos1 = await ClaimFactory.createClaim(
        payload: const SosPayload(location: location),
        originDeviceId: 'device-A',
      );

      final sos2 = await ClaimFactory.createClaim(
        payload: const SosPayload(location: location),
        originDeviceId: 'device-B',
      );

      expect(sos1.id, isNot(equals(sos2.id)));

      await repo.insertClaim(sos1);
      await repo.insertClaim(sos2);

      // Verify both persist separately without replacing each other
      final active = await repo.getActiveClaims();
      expect(active.length, 2);
      expect(active.map((c) => c.id).toSet().length, 2);
    });
  });
}
