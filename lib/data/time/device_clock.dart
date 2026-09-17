// lib/data/time/device_clock.dart

import 'package:shared_preferences/shared_preferences.dart';
import '../models/logical_clock.dart';

/// The device's persisted Lamport clock — CLAIM_SCHEMA.md §4.
///
/// **This is not `SequenceCounter`, and the two must never be unified.**
/// They are both monotonic per-device integers, which makes them look
/// interchangeable. They are not:
///
/// | | `SequenceCounter` | `DeviceClock` |
/// |---|---|---|
/// | Purpose | uniqueness of a **SOS claim id** (§2) | **causal ordering** between events (§4) |
/// | Moves on | this device originating a claim | send *and* receive (Lamport rule) |
/// | Written to | `claims.origin_sequence` | `claims.clock_*` |
///
/// A Lamport clock jumps forward when it hears a higher counter from another
/// device. A sequence number must never do that: it is hashed into the SOS
/// claim id, and an id that moves with mesh traffic would stop being a stable
/// identity for the person who raised it.
///
/// Before this class existed, `ClaimFactory` fed one `SequenceCounter` value
/// into both roles. That was correct only for as long as nothing ever applied
/// the receive-side Lamport rule — i.e. only until the receive pipeline was
/// built, which is exactly what this class exists to support.
class DeviceClock {
  static const String _key = 'mayday_lamport_counter';

  final String deviceId;

  const DeviceClock(this.deviceId);

  Future<int> _read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key) ?? 0;
  }

  Future<void> _write(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, value);
  }

  /// Current value without advancing it. For display and tests only —
  /// anything that originates a message must use [tickForSend].
  Future<LogicalClock> peek() async {
    return LogicalClock(deviceId: deviceId, counter: await _read());
  }

  /// Advances the clock for an event this device is originating, and returns
  /// the stamp to put on it. §4: "increments on every message this device sends".
  Future<LogicalClock> tickForSend() async {
    final next = await _read() + 1;
    await _write(next);
    return LogicalClock(deviceId: deviceId, counter: next);
  }

  /// Applies the Lamport receive rule: counter = max(local, remote) + 1.
  ///
  /// Called by the receive pipeline for every message that arrives, so that
  /// this device's later claims order correctly against what it has already
  /// heard. Returns the updated local clock.
  Future<LogicalClock> observeReceive(LogicalClock remote) async {
    final local = await _read();
    final merged = (local > remote.counter ? local : remote.counter) + 1;
    await _write(merged);
    return LogicalClock(deviceId: deviceId, counter: merged);
  }
}
