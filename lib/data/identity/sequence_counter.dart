// lib/data/identity/sequence_counter.dart

import 'package:shared_preferences/shared_preferences.dart';

/// Per-device monotonic sequence counter that never resets.
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
