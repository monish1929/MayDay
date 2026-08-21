// test/data/time_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/time/decay.dart';
import 'package:mayday/data/time/mesh_time.dart';

void main() {
  group('Decay Rules (§7)', () {
    test('SOS claims do not decay', () {
      expect(displayLifetimeFor(ClaimType.sos), isNull);
      expect(displayLifetimeFor(ClaimType.sosProxy), isNull);
    });

    test('Hazards and Resources decay based on named constants', () {
      expect(displayLifetimeFor(ClaimType.hazardReport), equals(hazardDisplayLifetime));
      expect(displayLifetimeFor(ClaimType.resource), equals(resourceDisplayLifetime));
    });

    test('Resource decays faster than Hazard', () {
      expect(resourceDisplayLifetime.inHours, lessThan(hazardDisplayLifetime.inHours));
    });
  });

  group('Logical Clock', () {
    test('Increments correctly', () {
      final clock1 = LogicalClock(deviceId: 'dev1', counter: 1);
      final clock2 = clock1.increment();
      
      expect(clock2.deviceId, equals('dev1'));
      expect(clock2.counter, equals(2));
    });

    test('Updates on receive', () {
      final local = LogicalClock(deviceId: 'dev1', counter: 5);
      final received = LogicalClock(deviceId: 'dev2', counter: 10);
      
      final updated = local.updateFromReceive(received);
      expect(updated.deviceId, equals('dev1'));
      expect(updated.counter, equals(11));
    });

    test('Comparable ordering', () {
      final clock1 = LogicalClock(deviceId: 'dev1', counter: 1);
      final clock2 = LogicalClock(deviceId: 'dev2', counter: 2);
      final clock3 = LogicalClock(deviceId: 'dev3', counter: 1);
      
      // Counter diff
      expect(clock1.compareTo(clock2), lessThan(0));
      expect(clock2.compareTo(clock1), greaterThan(0));
      
      // Tie breaker by device id
      // 'dev1' comes before 'dev3'
      expect(clock1.compareTo(clock3), lessThan(0));
      expect(clock3.compareTo(clock1), greaterThan(0));
      
      // Equality
      final clock4 = LogicalClock(deviceId: 'dev1', counter: 1);
      expect(clock1.compareTo(clock4), equals(0));
    });
  });

  group('Mesh Time Gossip', () {
    test('Displays relative time correctly', () {
      final gossip = MeshTimeGossip();
      
      // We don't really care about the exact MS mapping for this test,
      // just that formatRelativeTime works purely on UI level.
      final fakeNow = DateTime(2025, 1, 1, 12, 0, 0); // Noon
      
      final fewMinsAgo = fakeNow.subtract(const Duration(minutes: 5));
      expect(gossip.formatRelativeTime(fewMinsAgo, nowOverride: fakeNow), equals('about 5 minutes ago'));
      
      final fewHoursAgo = fakeNow.subtract(const Duration(hours: 3));
      expect(gossip.formatRelativeTime(fewHoursAgo, nowOverride: fakeNow), equals('about 3 hours ago'));
    });
  });
}
