// lib/identity/signature.dart

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'keypair.dart';

/// Ed25519 sign / verify — CLAIM_SCHEMA.md §5.
///
/// Lives in `identity/` rather than inside `mesh/` or `data/` because both
/// sides need it and neither owns it: `data/` signs a claim at origination,
/// `mesh/` verifies at every hop (§9.3 step 2). Putting the primitive in
/// either one would force the other to import across an ownership boundary.
///
/// **Claims are signed, never encrypted** (§2.5). Every relay has to read
/// content to draw the pin, compute the geohash bucket and corroborate. A
/// signature proves origin and integrity while leaving the payload readable —
/// that is the whole point, and it is not a step on the way to encryption.
class ClaimSignature {
  ClaimSignature._();

  static final Ed25519 _algorithm = Ed25519();

  /// Ed25519 signatures are always exactly this long.
  static const int signatureLength = 64;

  /// Ed25519 public keys are always exactly this long.
  static const int publicKeyLength = 32;

  /// Signs [message] with [keyPair], returning the raw 64 signature bytes.
  ///
  /// The caller decides what [message] is: `data/` signs
  /// `Claim.toSignedCoreCbor()`, `mesh/` signs `Envelope.signingPayload()`.
  /// Neither is this class's business — it moves bytes.
  static Future<Uint8List> sign(
    List<int> message,
    DeviceKeyPair keyPair,
  ) async {
    final signature = await _algorithm.sign(
      message,
      keyPair: keyPair.rawKeyPair,
    );
    return Uint8List.fromList(signature.bytes);
  }

  /// Verifies [signature] over [message] against [publicKey].
  ///
  /// **Never throws.** Returns false for anything that is not a good
  /// signature, including input that is malformed rather than merely wrong:
  /// a truncated signature, an empty public key, garbage bytes. On this
  /// transport the sender is a stranger's phone, so malformed input is an
  /// expected message and not a bug (§9.3: "invalid, malformed, or missing →
  /// drop"). A verifier that threw would turn a hostile packet into a crash
  /// on the receive path.
  static Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    try {
      if (signature.length != signatureLength) return false;
      if (publicKey.length != publicKeyLength) return false;

      return await _algorithm.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(
            publicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      // Any shape the library rejects outright is simply "not verified".
      return false;
    }
  }
}
