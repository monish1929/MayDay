// lib/mesh/messages/body_codec.dart

import 'package:cbor/cbor.dart';

import '../../data/models/logical_clock.dart';

/// Result of decoding an envelope `body` — CLAIM_SCHEMA.md §9.1.
///
/// Same rule as [EnvelopeDecodeResult] one level up: **nothing in `mesh/`
/// throws on untrusted input.** A malformed body is an expected message from
/// a stranger's phone, not a bug, and §9.3 says invalid/malformed/missing all
/// take one path — drop, do not relay, do not store. A decoder that threw
/// would turn a hostile packet into a crash on the receive path.
sealed class BodyDecodeResult<T> {
  const BodyDecodeResult();
}

class BodyDecodeOk<T> extends BodyDecodeResult<T> {
  final T body;
  const BodyDecodeOk(this.body);
}

class BodyDecodeError<T> extends BodyDecodeResult<T> {
  final String reason;
  const BodyDecodeError(this.reason);
}

/// Shared field readers for the positional CBOR arrays the non-claim message
/// kinds use.
///
/// Positional arrays, not maps, for the same reason §9.2 says enums serialize
/// as ints: every key name is bytes against a 400-byte envelope budget, and
/// these messages ride alongside claim traffic on the same radio.
class BodyFields {
  BodyFields._();

  /// Decodes `bytes` as a CBOR array of exactly [length] elements.
  static CborList? readArray(List<int> bytes, int length) {
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is! CborList) return null;
      if (decoded.length != length) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// Reads a byte string of an exact expected length, or null.
  ///
  /// The length check is not decoration: an Ed25519 public key that is not 32
  /// bytes cannot verify anything, and letting it through means carrying a
  /// value that looks like a key everywhere downstream.
  static List<int>? bytesOfLength(CborValue value, int length) {
    if (value is! CborBytes) return null;
    if (value.bytes.length != length) return null;
    return value.bytes;
  }

  /// Reads a non-negative integer, or null.
  static int? nonNegativeInt(CborValue value) {
    if (value is! CborSmallInt) return null;
    if (value.value < 0) return null;
    return value.value;
  }

  /// Reads an integer that indexes into an enum of [enumLength] values.
  static int? enumIndex(CborValue value, int enumLength) {
    final raw = nonNegativeInt(value);
    if (raw == null || raw >= enumLength) return null;
    return raw;
  }

  static String? text(CborValue value, {int maxLength = 128}) {
    if (value is! CborString) return null;
    final s = value.toString();
    // Bounded because this string is about to be written to SQLite and
    // rendered. A stranger controls its length; §9.2 caps free text at 80
    // characters and nothing on the wire needs more than an id's 64.
    if (s.isEmpty || s.length > maxLength) return null;
    return s;
  }

  static LogicalClock? clock(CborValue value) => LogicalClock.fromCbor(value);
}
