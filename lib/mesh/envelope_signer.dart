// lib/mesh/envelope_signer.dart

import 'dart:typed_data';

import '../identity/keypair.dart';
import '../identity/signature.dart';
import 'envelope.dart';

/// Signs outgoing envelopes and verifies incoming ones — CLAIM_SCHEMA.md §5,
/// §9.3 step 2.
///
/// Kept separate from [Envelope] so the envelope itself stays a pure data
/// structure with no crypto dependency: parsing bytes off the radio and
/// deciding whether to trust them are different jobs, and only the second
/// one needs a keypair.
class EnvelopeSigner {
  EnvelopeSigner._();

  /// Builds a signed envelope ready to transmit.
  ///
  /// `msgId` is generated fresh here because it is per-*transmission*, not
  /// per-claim (§9.1): the same claim re-sent later is a new message to the
  /// de-dup cache, and reusing the id would make every resend look like a
  /// duplicate and be dropped.
  static Future<Envelope> sign({
    required EnvelopeKind kind,
    required Uint8List body,
    required DeviceKeyPair keyPair,
    required int hopLimit,
    int v = Envelope.protocolVersion,
  }) async {
    // Signed over (v || kind || body) only — see Envelope.signingPayload().
    final signingBytes = Uint8List.fromList([v, kind.index, ...body]);
    final signature = await ClaimSignature.sign(signingBytes, keyPair);

    return Envelope(
      v: v,
      msgId: Envelope.generateMsgId(),
      hopLimit: hopLimit,
      kind: kind,
      body: body,
      originPubKey: keyPair.publicKey,
      originSig: signature,
    );
  }

  /// True only if `originSig` is a good signature over `(v || kind || body)`
  /// by the key in `originPubKey`.
  ///
  /// **Never throws** — malformed input returns false, because the sender is
  /// a stranger's phone and §9.3 says invalid/malformed/missing all take the
  /// same path: drop, do not relay, do not store.
  ///
  /// An all-zero or absent signature fails here like any other bad one. There
  /// is deliberately no "unsigned but acceptable" branch: §2.5 requires a
  /// signature on every claim, and a device that treated missing as
  /// acceptable would relay anything anyone shouted at it.
  ///
  /// **What this does NOT establish:** that the signer is anyone in
  /// particular. It proves the message was not tampered with in transit and
  /// that whoever holds this key produced it. Whether that key belongs to a
  /// vouched volunteer — or to a device presenting fifty identities — is
  /// `node_trust`, which needs Phase 4's vouching system and does not exist
  /// yet (`CLAUDE.md` §9: Sybil resistance is mitigated, not solved).
  static Future<bool> verify(Envelope envelope) async {
    return ClaimSignature.verify(
      envelope.signingPayload(),
      signature: envelope.originSig,
      publicKey: envelope.originPubKey,
    );
  }

  /// Confirms `claimedDeviceId` really is the id derived from this envelope's
  /// public key.
  ///
  /// Verification alone proves the holder of `originPubKey` signed the body.
  /// It does not stop them putting someone else's `originDeviceId` inside
  /// that body — which would let a device sign claims that appear to come
  /// from a neighbour, and, for SOS, mint ids in that neighbour's id space
  /// (§2). The receive pipeline pairs this with [verify] once it has decoded
  /// the body far enough to read the id.
  static bool matchesDeviceId(Envelope envelope, String claimedDeviceId) {
    if (envelope.originPubKey.length != Envelope.publicKeyLength) return false;
    return DeviceKeyPair.deviceIdForPublicKey(envelope.originPubKey) ==
        claimedDeviceId;
  }
}
