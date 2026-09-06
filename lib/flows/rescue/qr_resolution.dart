// lib/flows/rescue/qr_resolution.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../data/database/claim_repository.dart';
import '../../data/enums.dart';
import '../../data/models/claim.dart';
import '../../data/time/device_clock.dart';
import '../../identity/keypair.dart';
import '../../identity/signature.dart';
import '../../mesh/envelope.dart';
import '../../mesh/mesh_node.dart';
import '../../mesh/messages/resolution_message.dart';
import '../../mesh/resolution_ingestion.dart';

/// The half of a resolution that fits in a QR code — CLAIM_SCHEMA.md §6.2.
///
/// **Why not just the SOS id.** v1 of the design encoded the id alone, and
/// that cannot work: the id travels across the entire mesh in the clear, so
/// every device already knows it and anyone could fabricate the code and
/// clear a live emergency. What the QR has to prove is *presence*, not
/// knowledge — so it carries a nonce generated at the moment of display and a
/// signature from the person's own device key over both.
///
/// The volunteer's counter-signature is added when they scan it, and the pair
/// is what proves two specific devices were physically in the same place: a
/// QR has to be scanned with a camera, so they were in the same room.
class RescueQrPayload {
  final String sosId;
  final Uint8List nonce;
  final Uint8List requesterPubKey;
  final Uint8List requesterSig;

  const RescueQrPayload({
    required this.sosId,
    required this.nonce,
    required this.requesterPubKey,
    required this.requesterSig,
  });

  /// Base64url of a compact CBOR array — roughly 240 characters, comfortably
  /// inside what a phone camera reads reliably at arm's length in bad light,
  /// which is the condition this will actually be used in.
  ///
  /// Base64**url** specifically: a QR scanner library that hands back a string
  /// should not have to care about `+` and `/`.
  String encode() {
    final bytes = cbor.encode(CborList([
      CborString(sosId),
      CborBytes(nonce),
      CborBytes(requesterPubKey),
      CborBytes(requesterSig),
    ]));
    return base64Url.encode(bytes);
  }

  /// Reads a scanned QR string. Returns null on anything malformed.
  ///
  /// Never throws: the input is whatever the camera saw, which includes every
  /// other QR code in the world. A scanner that crashed on a shop receipt
  /// would be a scanner that stops working exactly when it is needed.
  static RescueQrPayload? decode(String scanned) {
    try {
      final decoded = cbor.decode(base64Url.decode(scanned.trim()));
      if (decoded is! CborList || decoded.length != 4) return null;

      final idField = decoded[0];
      final nonceField = decoded[1];
      final keyField = decoded[2];
      final sigField = decoded[3];

      if (idField is! CborString) return null;
      if (nonceField is! CborBytes ||
          nonceField.bytes.length != ResolutionMessage.nonceLength) {
        return null;
      }
      if (keyField is! CborBytes ||
          keyField.bytes.length != ClaimSignature.publicKeyLength) {
        return null;
      }
      if (sigField is! CborBytes ||
          sigField.bytes.length != ClaimSignature.signatureLength) {
        return null;
      }

      return RescueQrPayload(
        sosId: idField.toString(),
        nonce: Uint8List.fromList(nonceField.bytes),
        requesterPubKey: Uint8List.fromList(keyField.bytes),
        requesterSig: Uint8List.fromList(sigField.bytes),
      );
    } catch (_) {
      return null;
    }
  }

  /// Checks the requester's signature over `sosId || nonce`.
  Future<bool> verify() {
    return ClaimSignature.verify(
      ResolutionMessage.signingPayload(sosId, nonce),
      signature: requesterSig,
      publicKey: requesterPubKey,
    );
  }
}

/// Why a scan did not resolve anything.
enum ResolutionScanFailure {
  /// Not a MayDay resolution QR at all.
  unreadable,

  /// The requester's signature does not check out — a fabricated or
  /// tampered-with code.
  badRequesterSignature,
}

class ResolutionScanResult {
  final Envelope? envelope;
  final Claim? claim;
  final ResolutionScanFailure? failure;

  const ResolutionScanResult.resolved(Envelope this.envelope, this.claim)
      : failure = null;

  const ResolutionScanResult.failed(this.failure)
      : envelope = null,
        claim = null;

  bool get resolved => envelope != null;
}

/// Both ends of a QR rescue closure — PERSON_A.md Wk3 D3.
class RescueResolution {
  final MeshNode node;
  final ClaimRepository repository;
  final ResolutionIngestion ingestion;
  final DeviceClock deviceClock;

  RescueResolution({
    required this.node,
    required this.repository,
    required this.ingestion,
    required this.deviceClock,
  });

  /// Requester side: build the QR for an SOS this device raised.
  ///
  /// **Call this every time the code is shown, not once per claim.** The
  /// nonce is what makes the signature specific to one moment of display; a
  /// nonce reused across displays turns a photograph of the screen into a
  /// reusable key. Wk4 D4's replay test is written against exactly this.
  Future<RescueQrPayload> qrFor({
    required String sosId,
    required DeviceKeyPair requesterKeyPair,
  }) async {
    final nonce = ResolutionMessage.generateNonce();
    return RescueQrPayload(
      sosId: sosId,
      nonce: nonce,
      requesterPubKey: requesterKeyPair.publicKey,
      requesterSig: await ClaimSignature.sign(
        ResolutionMessage.signingPayload(sosId, nonce),
        requesterKeyPair,
      ),
    );
  }

  /// Volunteer side: counter-sign a scanned QR, apply it locally, flood it.
  ///
  /// The requester's signature is verified **before** anything is signed or
  /// stored. Counter-signing first would put this device's name on a
  /// resolution it had not checked — and that signature is the half other
  /// devices trust when they apply it.
  Future<ResolutionScanResult> resolveFromScan(
    String scanned, {
    ResolutionMethod method = ResolutionMethod.qr,
  }) async {
    final payload = RescueQrPayload.decode(scanned);
    if (payload == null) {
      return const ResolutionScanResult.failed(
        ResolutionScanFailure.unreadable,
      );
    }

    if (!await payload.verify()) {
      return const ResolutionScanResult.failed(
        ResolutionScanFailure.badRequesterSignature,
      );
    }

    final message = ResolutionMessage(
      sosId: payload.sosId,
      nonce: payload.nonce,
      requesterPubKey: payload.requesterPubKey,
      requesterSig: payload.requesterSig,
      method: method,
      resolvedAtLogical: await deviceClock.tickForSend(),
    );

    // Signed and queued for flood. The envelope signature is the volunteer's
    // counter-signature — it covers the whole body, requester signature
    // included.
    final envelope = await node.originateResolution(message);

    // Applied locally too. A volunteer standing in front of the person should
    // not have to wait for their own message to come back through the mesh to
    // see the pin close — and if this device holds no such claim, the
    // resolution is parked exactly as an inbound one would be.
    final claim = await repository.getClaim(payload.sosId);
    if (claim != null) {
      await ingestion.applyTo(
        claim,
        message,
        resolverPubKey: node.keyPair.publicKey,
      );
    } else {
      await ingestion.pending.park(
        message,
        resolverPubKey: node.keyPair.publicKey,
      );
    }

    return ResolutionScanResult.resolved(envelope, claim);
  }

  /// Manual fallback, for a phone that is dead, lost or damaged.
  ///
  /// **Always lower confidence, and it archives rather than clears** (§6.3):
  /// a mistaken or malicious manual resolve must not erase the record that
  /// somebody needed help. There is no requester signature to check here,
  /// which is exactly why it is tagged `manual` and why §6.3 treats it
  /// differently from a QR resolution everywhere downstream.
  ///
  /// **Open with B, not silently decided (CLAUDE.md §8):** this writes
  /// `status = resolved` and lets §6.4's windowed RESOLVED → ARCHIVED
  /// transition do the archiving, on the reading that "archives rather than
  /// clears" means *the record survives* rather than *skip straight to
  /// ARCHIVED*. Whether a manual resolve should jump the queue is a `data/`
  /// question and B's call — PERSON_A.md Wk3 D4 lists confirming it as a task.
  Future<ResolutionScanResult> resolveManually({
    required String sosId,
    required DeviceKeyPair requesterKeyPair,
  }) async {
    // A manual resolve still produces a signed, well-formed resolution: it is
    // the *provenance* that is weaker, not the message. Signing it with a key
    // this device holds keeps one code path on the wire instead of a second,
    // unsigned one — and an unsigned resolution would be a hole anyone could
    // walk through (§2.5).
    final message = await ResolutionMessage.forDisplay(
      sosId: sosId,
      requesterKeyPair: requesterKeyPair,
      resolvedAtLogical: await deviceClock.tickForSend(),
      method: ResolutionMethod.manual,
    );

    final envelope = await node.originateResolution(message);

    final claim = await repository.getClaim(sosId);
    if (claim != null) {
      await ingestion.applyTo(
        claim,
        message,
        resolverPubKey: node.keyPair.publicKey,
      );
    }

    return ResolutionScanResult.resolved(envelope, claim);
  }
}
