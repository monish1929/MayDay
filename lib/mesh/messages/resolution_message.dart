// lib/mesh/messages/resolution_message.dart

import 'dart:math';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../data/enums.dart';
import '../../data/models/logical_clock.dart';
import '../../identity/keypair.dart';
import '../../identity/signature.dart';
import 'body_codec.dart';

/// `kind: 2` — an SOS resolution, PERSON_A.md Wk3 D3 and CLAIM_SCHEMA.md §6.2.
///
/// **Two signatures, not one.** That is the whole point of the message:
///
/// - the **requester** signs `(sosId || nonce)` and shows it as a QR code,
/// - the **volunteer** optically scans it and counter-signs the entire body,
///   which is the envelope's `originSig`.
///
/// A signature pair like that can only be produced by two devices that were
/// physically in the same place, because a QR has to be scanned with a
/// camera. §6.2 is explicit about why a bare SOS id is not enough: the id
/// travels the whole mesh in the clear, so knowing it proves nothing at all —
/// anyone could fabricate a resolution and clear a live emergency.
///
/// The volunteer's public key and counter-signature are **not** repeated in
/// the body: they are `originPubKey` and `originSig` on the envelope (§9.1),
/// which every hop already verifies. Duplicating them would cost 96 bytes
/// against the 400-byte budget for no extra proof.
class ResolutionMessage {
  /// Bytes of freshness in the QR. Fresh per *display*, so a photographed QR
  /// cannot be re-presented later.
  static const int nonceLength = 16;

  /// The SOS being resolved. A claim id (§2), never a geohash-derived one —
  /// because SOS ids are unique per person, resolving one can never resolve a
  /// neighbour's (§6.2).
  final String sosId;

  /// Fresh random bytes generated at the moment the QR was displayed.
  final Uint8List nonce;

  /// Raw Ed25519 public key of the device that raised the SOS.
  final Uint8List requesterPubKey;

  /// Requester's Ed25519 signature over [signingPayload] — `sosId || nonce`.
  final Uint8List requesterSig;

  /// `qr` or `manual`. `autoExpired` is never valid for an SOS (§2.3, and
  /// `Claim`'s own constructor asserts it) and is rejected at decode.
  final ResolutionMethod method;

  /// The counter-signing volunteer's logical clock at the moment of scanning.
  /// Orders two resolutions for one SOS without any wall clock (§4).
  final LogicalClock resolvedAtLogical;

  const ResolutionMessage({
    required this.sosId,
    required this.nonce,
    required this.requesterPubKey,
    required this.requesterSig,
    required this.method,
    required this.resolvedAtLogical,
  });

  /// Fresh nonce for one QR display.
  ///
  /// `Random.secure()`, not `Random()`: a predictable nonce is a nonce an
  /// attacker can pre-compute a signature request around.
  static Uint8List generateNonce() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(nonceLength, (_) => rnd.nextInt(256)),
    );
  }

  /// The exact bytes the **requester** signs: `sosId || nonce`.
  ///
  /// Both, never just the id. The id alone is public knowledge (§6.2); the
  /// nonce is what makes each signature specific to one moment of display.
  static Uint8List signingPayload(String sosId, List<int> nonce) {
    return Uint8List.fromList([...sosId.codeUnits, ...nonce]);
  }

  /// Builds the requester half — called on the device raising the SOS when it
  /// puts a QR on screen.
  static Future<ResolutionMessage> forDisplay({
    required String sosId,
    required DeviceKeyPair requesterKeyPair,
    required LogicalClock resolvedAtLogical,
    ResolutionMethod method = ResolutionMethod.qr,
    Uint8List? nonce,
  }) async {
    final n = nonce ?? generateNonce();
    return ResolutionMessage(
      sosId: sosId,
      nonce: n,
      requesterPubKey: requesterKeyPair.publicKey,
      requesterSig:
          await ClaimSignature.sign(signingPayload(sosId, n), requesterKeyPair),
      method: method,
      resolvedAtLogical: resolvedAtLogical,
    );
  }

  /// Verifies the requester's half, independently of the envelope.
  ///
  /// Never throws — `ClaimSignature.verify` returns false for malformed input
  /// rather than raising, which is the contract the whole receive path is
  /// built on (§9.3).
  Future<bool> verifyRequesterSignature() {
    return ClaimSignature.verify(
      signingPayload(sosId, nonce),
      signature: requesterSig,
      publicKey: requesterPubKey,
    );
  }

  Uint8List encode() {
    return Uint8List.fromList(cbor.encode(CborList([
      CborString(sosId),
      CborBytes(nonce),
      CborBytes(requesterPubKey),
      CborBytes(requesterSig),
      CborSmallInt(method.index),
      resolvedAtLogical.toCbor(),
    ])));
  }

  static BodyDecodeResult<ResolutionMessage> decode(List<int> bytes) {
    final list = BodyFields.readArray(bytes, 6);
    if (list == null) return const BodyDecodeError('expected a 6-field array');

    // Claim ids are 64-char SHA-256 hex (see generateSosClaimId), so 64 is
    // both the expected and the maximum sane length.
    final sosId = BodyFields.text(list[0], maxLength: 64);
    if (sosId == null) return const BodyDecodeError('sosId: expected text');

    final nonce = BodyFields.bytesOfLength(list[1], nonceLength);
    if (nonce == null) {
      return const BodyDecodeError('nonce: expected $nonceLength bytes');
    }

    final pubKey =
        BodyFields.bytesOfLength(list[2], ClaimSignature.publicKeyLength);
    if (pubKey == null) {
      return const BodyDecodeError('requesterPubKey: wrong length');
    }

    final sig =
        BodyFields.bytesOfLength(list[3], ClaimSignature.signatureLength);
    if (sig == null) return const BodyDecodeError('requesterSig: wrong length');

    final methodIndex =
        BodyFields.enumIndex(list[4], ResolutionMethod.values.length);
    if (methodIndex == null) {
      return const BodyDecodeError('method: not a ResolutionMethod');
    }
    final method = ResolutionMethod.values[methodIndex];

    // An SOS never expires (§2.3), so a resolution asserting `autoExpired`
    // over one is either a bug or an attempt to make a rescue disappear by
    // claiming it timed out. `Claim`'s constructor asserts the same thing,
    // but asserts are compiled out of release builds and this is the wire.
    if (method == ResolutionMethod.autoExpired) {
      return const BodyDecodeError(
        'method: autoExpired is never valid for an SOS (§2.3)',
      );
    }

    final clock = BodyFields.clock(list[5]);
    if (clock == null) {
      return const BodyDecodeError('resolvedAtLogical: malformed clock');
    }

    return BodyDecodeOk(ResolutionMessage(
      sosId: sosId,
      nonce: Uint8List.fromList(nonce),
      requesterPubKey: Uint8List.fromList(pubKey),
      requesterSig: Uint8List.fromList(sig),
      method: method,
      resolvedAtLogical: clock,
    ));
  }
}
