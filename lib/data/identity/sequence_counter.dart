// lib/data/identity/sequence_counter.dart

import 'package:shared_preferences/shared_preferences.dart';

/// Per-device monotonic sequence counter that never resets.
///
/// **Not a logical clock.** This only ever counts claims *this* device has
/// originated, because it is hashed into the SOS claim id (§2) and that id
/// must stay stable for the person who raised it. It must never jump forward
/// in response to mesh traffic — for causal ordering, see `DeviceClock`
/// (`lib/data/time/device_clock.dart`, §4).
class SequenceCounter {
  static const String _key = 'mayday_local_sequence_number';

  /// Increments the local sequence counter and returns the new value.
  /// Used for generating unique SOS claim IDs.
  static Future<int> getNextSequence() async {
    final prefs = await SharedPreferences.getInstance();
    int current = prefs.getInt(_key) ?? 0;
    current++;
    await prefs.setInt(_key, current);
    return current;
  }
}
