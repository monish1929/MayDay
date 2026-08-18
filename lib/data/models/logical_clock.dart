// lib/data/models/logical_clock.dart

class LogicalClock {
  final String deviceId;
  final int counter;

  const LogicalClock({
    required this.deviceId,
    required this.counter,
  });
}
