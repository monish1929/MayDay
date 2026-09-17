import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the local device identifier.
///
/// In Week 2, a persistent random device ID is generated and stored in SharedPreferences.
/// Real Ed25519 public-key-derived device identity is scheduled for Phase 4 (lib/identity/).
class LocalDeviceId {
  static const String _prefKey = 'mayday_local_device_id';
  static String? _cachedDeviceId;

  /// Retrieves the persistent local device identifier, generating and persisting
  /// a new one if not already set.
  static Future<String> getDeviceId() async {
    if (_cachedDeviceId != null) {
      return _cachedDeviceId!;
    }

    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString(_prefKey);
    if (id == null || id.isEmpty) {
      final random = Random();
      final randomHex = List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
      id = 'dev-$randomHex';
      await prefs.setString(_prefKey, id);
    }

    _cachedDeviceId = id;
    return id;
  }

  /// Sets a specific device ID (used in testing).
  static void setOverride(String? deviceId) {
    _cachedDeviceId = deviceId;
  }
}
