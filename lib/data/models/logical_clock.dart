// lib/data/models/logical_clock.dart

import 'package:cbor/cbor.dart';
class LogicalClock implements Comparable<LogicalClock> {
  final String deviceId;
  final int counter;

  const LogicalClock({
    required this.deviceId,
    required this.counter,
  });

  /// Compares this logical clock with another.
  /// Used for ordering events between devices.
  /// If devices are different, we primarily order by the counter value.
  /// For tie-breaking when counters are equal, we fallback to deviceId.
  @override
  int compareTo(LogicalClock other) {
    final counterCmp = counter.compareTo(other.counter);
    if (counterCmp != 0) {
      return counterCmp;
    }
    return deviceId.compareTo(other.deviceId);
  }

  /// Increments the logical clock counter
  LogicalClock increment() {
    return LogicalClock(
      deviceId: deviceId,
      counter: counter + 1,
    );
  }

  /// When receiving a message, update the logical clock to the max of current and received, plus one.
  /// (Lamport clock behavior: updates on both send and receive)
  LogicalClock updateFromReceive(LogicalClock received) {
    return LogicalClock(
      deviceId: deviceId,
      counter: (counter > received.counter ? counter : received.counter) + 1,
    );
  }

  CborValue toCbor() {
    return CborList([
      CborString(deviceId),
      CborSmallInt(counter),
    ]);
  }

  /// Rebuilds a clock from wire bytes. Returns null on anything malformed --
  /// callers are on the receive path, where bad input is expected rather
  /// than exceptional (CLAIM_SCHEMA.md §9.3).
  static LogicalClock? fromCbor(CborValue value) {
    if (value is! CborList || value.length != 2) return null;
    final device = value[0];
    final counter = value[1];
    if (device is! CborString || counter is! CborSmallInt) return null;
    return LogicalClock(deviceId: device.toString(), counter: counter.value);
  }
}
