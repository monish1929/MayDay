// lib/identity/keypair.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device's Ed25519 identity — CLAIM_SCHEMA.md §5.
///
/// This keypair is the *only* source of `originDeviceId`. It is deliberately
/// not the BLE address: Android rotates that per advertising session, so a
/// claim keyed to it would change identity mid-mesh
/// (`PHASE0_MESH_FINDINGS.md` §7, seen three times on real hardware).
class DeviceKeyPair {
  /// Ed25519 seed length — what [persistableSeed] returns.
  static const int seedLength = 32;

  static const String _seedKey = 'mayday_device_key_seed';

  static final Ed25519 _algorithm = Ed25519();

  /// The underlying keypair. `ClaimSignature.sign` needs this; nothing else
  /// should reach for it.
  final SimpleKeyPair rawKeyPair;

  /// Raw 32-byte Ed25519 public key. Travels with claims so any relay can
  /// verify without asking anyone (§5: verification is purely local).
  final Uint8List publicKey;

  const DeviceKeyPair._(this.rawKeyPair, this.publicKey);

  /// `originDeviceId` for every claim this device raises: the first 16 bytes
  /// of SHA-256 over the public key, hex encoded (32 characters).
  ///
  /// Derived rather than random so that any device holding the public key can
  /// confirm the id matches the key that signed the claim — otherwise a claim
  /// could name someone else's device id while carrying its own signature.
  ///
  /// Truncated to 16 bytes because this string is CBOR-encoded into every
  /// claim, twice (`originDeviceId` and `logicalClock.deviceId`), against the
  /// 400-byte envelope budget (§9.2). Full 32-byte hex would cost ~64 bytes
  /// more per claim for collision resistance a local mesh does not need.
  String get deviceId => deviceIdForPublicKey(publicKey);

  /// Derives a device id from a raw public key.
  ///
  /// Static because a verifier holds the sender.s public key straight off
  /// the wire and never their keypair -- this is how a relay checks that a
  /// claimed `originDeviceId` matches the key that actually signed.
  static String deviceIdForPublicKey(List<int> publicKey) {
    final digest = crypto.sha256.convert(publicKey).bytes;
    return _hex(digest.sublist(0, 16));
  }

  /// A brand new random identity.
  static Future<DeviceKeyPair> generate() async {
    final keyPair = await _algorithm.newKeyPair();
    return DeviceKeyPair._(keyPair, await _publicKeyBytes(keyPair));
  }

  /// Rebuilds an identity from a stored seed. Same seed always yields the
  /// same keypair, and therefore the same [deviceId].
  static Future<DeviceKeyPair> fromSeed(List<int> seed) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    return DeviceKeyPair._(keyPair, await _publicKeyBytes(keyPair));
  }

  /// The 32-byte seed this identity can be rebuilt from. This is secret key
  /// material — see the warning on [loadOrCreateProvisional].
  Future<Uint8List> persistableSeed() async {
    return Uint8List.fromList(await rawKeyPair.extractPrivateKeyBytes());
  }

  /// Loads the device identity, creating one on first run.
  ///
  /// **PROVISIONAL — NOT SECURE STORAGE. Phase 4 must replace this.**
  ///
  /// The seed is written to `SharedPreferences`, which is plaintext on disk
  /// and readable by anything with root or a backup extraction. It exists so
  /// Phase 2 has a stable identity to sign with on a real device; it is not a
  /// key store. Real storage is Android Keystore, which is `identity/`'s
  /// Phase 4 scope — and note that Keystore keys do not survive app uninstall
  /// (`CLAUDE.md` §9), which is exactly why recovery is via vouching.
  ///
  /// Nothing security-sensitive should be built on top of this in the
  /// meantime. It is a placeholder that keeps the signing path testable.
  static Future<DeviceKeyPair> loadOrCreateProvisional() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_seedKey);

    if (stored != null) {
      return fromSeed(base64Decode(stored));
    }

    final fresh = await generate();
    await prefs.setString(_seedKey, base64Encode(await fresh.persistableSeed()));
    return fresh;
  }

  static Future<Uint8List> _publicKeyBytes(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  static String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
