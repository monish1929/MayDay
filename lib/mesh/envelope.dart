// lib/mesh/envelope.dart

import 'dart:math';
import 'dart:typed_data';
import 'package:cbor/cbor.dart';

/// Wire message kind — CLAIM_SCHEMA.md §9.1. Values are the enum index,
/// which must stay in this exact order: it's what travels on the wire.
enum EnvelopeKind {
  claim, // 0
  corroboration, // 1
  resolution, // 2
  vouch, // 3
  revocation, // 4
  volunteerBeacon, // 5
  timeGossip, // 6
}

/// mesh/ never throws on untrusted input — a malformed envelope is an
/// expected message from a stranger's phone, not a bug. Decoding returns
/// one of these instead of throwing, so a caller can't accidentally treat
/// "drop silently" (CLAIM_SCHEMA.md §9.3) as an unhandled exception.
sealed class EnvelopeDecodeResult {
  const EnvelopeDecodeResult();
}

class EnvelopeDecodeOk extends EnvelopeDecodeResult {
  final Envelope envelope;
  const EnvelopeDecodeOk(this.envelope);
}

class EnvelopeDecodeError extends EnvelopeDecodeResult {
  final String reason;
  const EnvelopeDecodeError(this.reason);
}

/// Transport-level wire message — CLAIM_SCHEMA.md §9.1.
///
/// mesh/ moves opaque signed bytes; it does not interpret what's inside
/// `body` beyond `kind`. Trust, decay, merging and claim identity are
/// entirely data/'s job (CLAUDE.md §1).
class Envelope {
  static const int protocolVersion = 1;
  static const int msgIdLength = 16;
  static const int signatureLength = 64;

  final int v;
  final Uint8List msgId; // random per TRANSMISSION, never the claim's own id — §9.1
  final int hopLimit; // decremented at each hop
  final EnvelopeKind kind;
  final Uint8List body; // CBOR, shape depends on kind
  final Uint8List originSig; // Ed25519 over (v || kind || body) — see signingPayload()

  const Envelope({
    required this.v,
    required this.msgId,
    required this.hopLimit,
    required this.kind,
    required this.body,
    required this.originSig,
  });

  /// Fresh id for this transmission, not the claim's identity. A claim gets
  /// resent many times over its life; each send needs its own msgId for the
  /// de-dup cache, or every resend after the first would be silently dropped.
  static Uint8List generateMsgId() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(msgIdLength, (_) => rnd.nextInt(256)),
    );
  }

  /// Bytes `originSig` is computed over: (v || kind || body).
  ///
  /// Deliberately excludes `hopLimit` and `msgId` — both change at every
  /// hop, and signing them would invalidate the signature after the first
  /// forward. Same principle as CLAIM_SCHEMA.md §5's "sign the immutable
  /// core" rule for a Claim itself, applied at the transport layer.
  Uint8List signingPayload() {
    return Uint8List.fromList([v, kind.index, ...body]);
  }

  CborValue toCbor() {
    return CborList([
      CborSmallInt(v),
      CborBytes(msgId),
      CborSmallInt(hopLimit),
      CborSmallInt(kind.index),
      CborBytes(body),
      CborBytes(originSig),
    ]);
  }

  Uint8List encode() => Uint8List.fromList(cbor.encode(toCbor()));

  static EnvelopeDecodeResult fromCbor(CborValue value) {
    try {
      if (value is! CborList) {
        return EnvelopeDecodeError(
          'expected a CBOR array, got ${value.runtimeType}',
        );
      }
      if (value.length != 6) {
        return EnvelopeDecodeError(
          'expected 6 fields, got ${value.length}',
        );
      }

      final vField = value[0];
      final msgIdField = value[1];
      final hopLimitField = value[2];
      final kindField = value[3];
      final bodyField = value[4];
      final sigField = value[5];

      if (vField is! CborSmallInt) {
        return const EnvelopeDecodeError('v: expected an integer');
      }
      if (msgIdField is! CborBytes) {
        return const EnvelopeDecodeError('msgId: expected bytes');
      }
      if (hopLimitField is! CborSmallInt) {
        return const EnvelopeDecodeError('hopLimit: expected an integer');
      }
      if (kindField is! CborSmallInt) {
        return const EnvelopeDecodeError('kind: expected an integer');
      }
      if (bodyField is! CborBytes) {
        return const EnvelopeDecodeError('body: expected bytes');
      }
      if (sigField is! CborBytes) {
        return const EnvelopeDecodeError('originSig: expected bytes');
      }

      if (kindField.value < 0 || kindField.value >= EnvelopeKind.values.length) {
        return EnvelopeDecodeError('kind: unknown value ${kindField.value}');
      }
      if (msgIdField.bytes.length != msgIdLength) {
        return EnvelopeDecodeError(
          'msgId: expected $msgIdLength bytes, got ${msgIdField.bytes.length}',
        );
      }
      if (sigField.bytes.length != signatureLength) {
        return EnvelopeDecodeError(
          'originSig: expected $signatureLength bytes, got ${sigField.bytes.length}',
        );
      }

      return EnvelopeDecodeOk(Envelope(
        v: vField.value,
        msgId: Uint8List.fromList(msgIdField.bytes),
        hopLimit: hopLimitField.value,
        kind: EnvelopeKind.values[kindField.value],
        body: Uint8List.fromList(bodyField.bytes),
        originSig: Uint8List.fromList(sigField.bytes),
      ));
    } catch (e) {
      // Any unexpected shape (truncated bytes, wrong nesting, a stranger's
      // malformed packet) becomes a typed failure, never an uncaught throw.
      return EnvelopeDecodeError('unexpected decode error: $e');
    }
  }

  static EnvelopeDecodeResult decode(Uint8List bytes) {
    try {
      final value = cbor.decode(bytes);
      return fromCbor(value);
    } catch (e) {
      return EnvelopeDecodeError('malformed CBOR: $e');
    }
  }
}
