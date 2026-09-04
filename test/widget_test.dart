import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mayday/main.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/screens/volunteer_ops_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('MayDayApp app shell smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MayDayApp());
    expect(find.text('MayDay'), findsWidgets);
    expect(find.text('User'), findsOneWidget);
    expect(find.text('Volunteer'), findsOneWidget);
  });

  test('ClaimDisplayHelpers sorting logic verifies rescue and hazard sorting', () async {
    final claimLow = await ClaimFactory.createClaim(
      originDeviceId: 'dev-1',
      payload: const SosPayload(location: GeoPoint(lat: 12.97, lon: 77.59)),
    );
    claimLow.dispatchPriority = DispatchPriority.low;
    claimLow.claimTrust = ClaimTrust.unconfirmed;

    final claimEnRoute = await ClaimFactory.createClaim(
      originDeviceId: 'dev-2',
      payload: const SosPayload(location: GeoPoint(lat: 12.98, lon: 77.60)),
    );
    claimEnRoute.dispatchPriority = DispatchPriority.enRoute;
    claimEnRoute.claimTrust = ClaimTrust.corroborated;

    final rescueClaims = [claimLow, claimEnRoute]..sort(ClaimDisplayHelpers.compareRescueClaims);

    expect(rescueClaims.first.dispatchPriority, DispatchPriority.enRoute);

    final hazard1 = await ClaimFactory.createClaim(
      originDeviceId: 'dev-1',
      payload: const HazardReportPayload(
        location: GeoPoint(lat: 12.97, lon: 77.59),
        hazardType: HazardType.flood,
        confirmationCount: 5,
      ),
    );
    final hazard2 = await ClaimFactory.createClaim(
      originDeviceId: 'dev-2',
      payload: const HazardReportPayload(
        location: GeoPoint(lat: 12.98, lon: 77.60),
        hazardType: HazardType.roadBlock,
        confirmationCount: 15,
      ),
    );

    final hazardClaims = [hazard1, hazard2]..sort(ClaimDisplayHelpers.compareHazardClaims);

    expect((hazardClaims.first.payload as HazardReportPayload).confirmationCount, 15);
  });

  test('ClaimDisplayHelpers relative time & aging logic', () {
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(const LogicalClock(deviceId: 'dev-1', counter: 1)),
      'Clock #1',
    );
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(const LogicalClock(deviceId: 'dev-1', counter: 42)),
      'Clock #42',
    );
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(null),
      'Recently',
    );
  });

  testWidgets('VolunteerOpsScreen renders tabs and lists', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VolunteerOpsScreen(),
      ),
    );

    expect(find.text('Volunteer Ops'), findsOneWidget);
    expect(find.textContaining('Rescue'), findsWidgets);
    expect(find.textContaining('Reports'), findsOneWidget);
    expect(find.textContaining('Resources'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
  });
}
