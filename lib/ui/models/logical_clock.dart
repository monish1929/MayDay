/// Logical clock — CLAIM_SCHEMA.md §4.
/// No device can trust its own wall clock (no network to sync from).
/// Ordering between events uses this counter, never DateTime.
class LogicalClock {
  final String deviceId;
  final int counter;

  const LogicalClock({required this.deviceId, required this.counter});

  @override
  String toString() => 'LogicalClock($deviceId, $counter)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogicalClock &&
          deviceId == other.deviceId &&
          counter == other.counter;

  @override
  int get hashCode => Object.hash(deviceId, counter);
}
