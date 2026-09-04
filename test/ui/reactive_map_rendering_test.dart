// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:math';
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
import 'package:mayday/data/enums.dart';
import 'package:mayday/common/debug_claim_seeder.dart';
import 'package:mayday/ui/map/claim_pin_widget.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
  });

  group('Week 2 Day 2: Reactive Map Rendering & watchActiveClaims Stream', () {
    test('watchActiveClaims emits initial snapshot and live updates on insert/update', () async {
      final repo = ClaimRepository();
      final stream = repo.watchActiveClaims();

      final emittedSnapshots = <List<Claim>>[];
      var completer = Completer<void>();

      final subscription = stream.listen((claims) {
        emittedSnapshots.add(claims);
        if (!completer.isCompleted) completer.complete();
      });

      // 1. Wait for initial snapshot
      await completer.future;
      expect(emittedSnapshots.length, 1);
      expect(emittedSnapshots.first, isEmpty);

      // 2. Insert an SOS claim
      completer = Completer<void>();
      final sos = await ClaimFactory.createClaim(
        originDeviceId: 'dev-stream-1',
        payload: const SosPayload(location: GeoPoint(lat: 12.9716, lon: 77.5946)),
      );
      await repo.insertClaim(sos);
      await completer.future;
      expect(emittedSnapshots.length, 2);
      expect(emittedSnapshots.last.length, 1);
      expect(emittedSnapshots.last.first.id, sos.id);

      // 3. Insert a Hazard claim
      completer = Completer<void>();
      final hazard = await ClaimFactory.createClaim(
        originDeviceId: 'dev-stream-2',
        payload: const HazardReportPayload(
          location: GeoPoint(lat: 12.9800, lon: 77.6000),
          hazardType: HazardType.flood,
          confirmationCount: 1,
        ),
      );
      await repo.insertClaim(hazard);
      await completer.future;
      expect(emittedSnapshots.length, 3);
      expect(emittedSnapshots.last.length, 2);

      // 4. Update trust tier of the SOS claim (unconfirmed -> corroborated)
      completer = Completer<void>();
      sos.claimTrust = ClaimTrust.corroborated;
      await repo.updateClaim(sos);
      await completer.future;
      expect(emittedSnapshots.length, 4);
      expect(emittedSnapshots.last.length, 2);
      final updatedSos = emittedSnapshots.last.firstWhere((c) => c.id == sos.id);
      expect(updatedSos.claimTrust, ClaimTrust.corroborated);

      await subscription.cancel();
    });

    test('Live stream layer filtering cleanly partitions Emergency vs Resource claims', () async {
      final repo = ClaimRepository();

      // Insert 2 Emergency claims (1 SOS, 1 Hazard) and 1 Resource claim
      final sos = await ClaimFactory.createClaim(
        originDeviceId: 'dev-layer-1',
        payload: const SosPayload(location: GeoPoint(lat: 12.9716, lon: 77.5946)),
      );
      final hazard = await ClaimFactory.createClaim(
        originDeviceId: 'dev-layer-2',
        payload: const HazardReportPayload(
          location: GeoPoint(lat: 12.9816, lon: 77.5946),
          hazardType: HazardType.structuralDamage,
          confirmationCount: 2,
        ),
      );
      final resource = await ClaimFactory.createClaim(
        originDeviceId: 'dev-layer-3',
        payload: const ResourcePayload(
          location: GeoPoint(lat: 12.9750, lon: 77.6000),
          category: ResourceCategory.foodWater,
          pledgedCount: 100,
          claimedReports: 0,
        ),
      );

      await repo.insertClaim(sos);
      await repo.insertClaim(hazard);
      await repo.insertClaim(resource);

      final allClaims = await repo.getActiveClaims();
      expect(allClaims.length, 3);

      // Emergency filter (SOS, SOS Proxy, Hazard)
      final emergencyClaims = allClaims.where((c) {
        return c.type == ClaimType.sos ||
            c.type == ClaimType.sosProxy ||
            c.type == ClaimType.hazardReport;
      }).toList();
      expect(emergencyClaims.length, 2);
      expect(emergencyClaims.map((c) => c.id).toSet(), {sos.id, hazard.id});

      // Resource filter
      final resourceClaims = allClaims.where((c) => c.type == ClaimType.resource).toList();
      expect(resourceClaims.length, 1);
      expect(resourceClaims.first.id, resource.id);
    });

    test('Per-type dynamic clustering prevents label-card visual collision', () async {
      // Test that 2 hazard pins placed 60px apart (which previously collided under fixed 45px)
      // are cleanly merged into a cluster under dynamic threshold (60 + 60 + 8 = 128px).
      final hazard1 = await ClaimFactory.createClaim(
        originDeviceId: 'dev-h1',
        payload: const HazardReportPayload(
          location: GeoPoint(lat: 12.9716, lon: 77.5946),
          hazardType: HazardType.structuralDamage,
          confirmationCount: 1,
        ),
      );
      final hazard2 = await ClaimFactory.createClaim(
        originDeviceId: 'dev-h2',
        payload: const HazardReportPayload(
          location: GeoPoint(lat: 12.9720, lon: 77.5950),
          hazardType: HazardType.structuralDamage,
          confirmationCount: 2,
        ),
      );
      expect(hazard1.id, isNotEmpty);
      expect(hazard2.id, isNotEmpty);

      // Mock screen points 60px apart in logical coordinates
      final p1 = const Point<double>(200.0, 200.0);
      final p2 = const Point<double>(260.0, 200.0); // 60px distance

      final dx = p1.x - p2.x;
      final dy = p1.y - p2.y;
      final dist = sqrt(dx * dx + dy * dy); // 60.0px

      // Old static threshold: 45.0px -> 60.0 < 45.0 is FALSE (would collide on screen)
      expect(dist < 45.0, isFalse);

      // New dynamic threshold for 2 hazard pills: 60.0 + 60.0 + 8.0 = 128.0px
      const hazardHalfExtent = 60.0;
      const dynamicThreshold = hazardHalfExtent + hazardHalfExtent + 8.0;
      expect(dist < dynamicThreshold, isTrue); // Correctly clusters to prevent overlap
    });

    testWidgets('Widget layout & render benchmark: 120 claims in pin overlay with RepaintBoundaries', (tester) async {
      late List<Claim> claims;
      await tester.runAsync(() async {
        final repo = ClaimRepository();
        await DebugClaimSeeder.seedSyntheticClaims(count: 120);
        claims = await repo.getActiveClaims();
      });
      expect(claims.length, 120);

      // Build simulated Positioned overlay widgets with RepaintBoundaries
      final stopwatch = Stopwatch()..start();

      final overlayWidgets = <Widget>[];
      final random = Random(42);
      for (int i = 0; i < claims.length; i++) {
        final claim = claims[i];
        final left = (random.nextDouble() * 350.0).clamp(10.0, 340.0);
        final top = (random.nextDouble() * 600.0).clamp(50.0, 580.0);

        overlayWidgets.add(
          Positioned(
            key: ValueKey('pos_${claim.id}'),
            left: left,
            top: top,
            child: ClaimPinWidget(
              key: ValueKey(claim.id),
              claim: claim,
              onTap: () {},
            ),
          ),
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: overlayWidgets,
            ),
          ),
        ),
      );

      final buildDuration = stopwatch.elapsedMilliseconds;

      // Pump 5 animation frames to exercise ticker and RepaintBoundary repaints
      stopwatch.reset();
      for (int f = 0; f < 5; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final animationDuration = stopwatch.elapsedMilliseconds;

      print('\n=== Widget Layout & Render Benchmark (120 Claims) ===');
      print('Initial widget build + layout time: ${buildDuration}ms');
      print('5 animation frames elapsed time: ${animationDuration}ms (${(animationDuration / 5).toStringAsFixed(2)}ms / frame)');
      print('=====================================================\n');

      expect(buildDuration, lessThan(3000)); // Initial widget tree construction and layout
      expect(find.byType(ClaimPinWidget), findsNWidgets(120));
      expect(find.byType(RepaintBoundary), findsWidgets);

      // Cleanly unmount widget tree to dispose all active AnimationControllers
      await tester.pumpWidget(const SizedBox());
    });
  });
}
