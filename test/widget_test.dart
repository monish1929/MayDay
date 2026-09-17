import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mayday/main.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/screens/volunteer_ops_screen.dart';

void main() {
  testWidgets('MayDayApp app shell smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MayDayApp());
    expect(find.text('MayDay'), findsWidgets);
    expect(find.text('User'), findsOneWidget);
    expect(find.text('Volunteer'), findsOneWidget);
  });

  test('ClaimDisplayHelpers sorting logic verifies rescue and hazard sorting', () {
    final claims = MockData.generateMockClaims();
    final rescueClaims = claims
        .where((c) =>
            (c.type == ClaimType.sos || c.type == ClaimType.sosProxy) &&
            c.status == ClaimStatus.active)
        .toList()
      ..sort(ClaimDisplayHelpers.compareRescueClaims);

    expect(rescueClaims.isNotEmpty, isTrue);
    // Highest priority claim should be first
    expect(rescueClaims.first.dispatchPriority, DispatchPriority.enRoute);

    final hazardClaims = claims
        .where((c) =>
            c.type == ClaimType.hazardReport && c.status == ClaimStatus.active)
        .toList()
      ..sort(ClaimDisplayHelpers.compareHazardClaims);

    expect(hazardClaims.isNotEmpty, isTrue);
    // Most confirmed hazard first (hazard-001 has 12 reports)
    final topHazard = hazardClaims.first.payload as HazardReportPayload;
    expect(topHazard.confirmationCount, 12);
  });

  test('ClaimDisplayHelpers relative time & aging logic', () {
    final now = DateTime.now();
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(now.subtract(const Duration(seconds: 30))),
      'Just now',
    );
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(now.subtract(const Duration(minutes: 15))),
      '15 min ago',
    );
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(now.subtract(const Duration(hours: 1))),
      'About 1 hour ago',
    );
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(now.subtract(const Duration(hours: 4))),
      'About 4 hours ago',
    );
    expect(
      ClaimDisplayHelpers.relativeTimeLabel(now.subtract(const Duration(days: 2))),
      '2 days ago',
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

    // Verify rescue cards render
    expect(find.text('Self-Raised SOS'), findsWidgets);
    expect(find.text('Proxy SOS'), findsOneWidget);
  });
}
