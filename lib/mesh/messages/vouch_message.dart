// lib/mesh/messages/vouch_message.dart

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../data/models/logical_clock.dart';
import '../../identity/signature.dart';
import 'body_codec.dart';

/// `kind: 3` — one volunteer vouching for another person, PERSON_A.md Wk4 D1
/// and MAYDAY_PROJECT_CONTEXT.md §2.2.
///
/// This is how someone who turns up mid-disaster becomes a volunteer with no
/// server, no cell tower and no campaign desk: an already-verified volunteer
/// signs "I know this person", and the vouch propagates like any other signed
/// message. Any device can check it on its own, because everything needed to
/// check it travels inside it.
///
/// The **voucher's** key and signature are the envelope's `originPubKey` and
/// `originSig` (§9.1) — not repeated here, for the same 400-byte-budget
/// reason as [ResolutionMessage]. What the body carries is who is being
/// vouched for and under what cap.
class VouchMessage {
  /// The cap a device will honour, regardless of what a vouch asks for.
  ///
  /// §2.2: "Cap of 5 vouches per verified volunteer, carried inside the
  /// signed vouch so any device can check it independently." Carried on the
  /// wire *and* bounded here — a voucher that writes `vouchCap: 500` into its
  /// own signed message has signed something perfectly valid and completely
  /// self-serving, and "carried inside the vouch" only helps if the receiver
  /// also refuses to believe an absurd one.
  static const int maxVouchCap = 5;

  /// Raw Ed25519 public key of the person being vouched for.
  final Uint8List voucheePubKey;

  /// Which of the voucher's vouches this is, 1-based.
  ///
  /// Self-asserted, and therefore **not** the enforcement mechanism: a
  /// dishonest voucher can stamp `1` on all fifty of its vouches. Enforcement
  /// is the receiver counting distinct vouchees per voucher
  /// (see `VouchRegistry`). This field is a cheap self-consistency check and
  /// a diagnostic, nothing more.
  final int vouchIndex;

  /// The cap the voucher asserts it is operating under. Expected to be
  /// [maxVouchCap]; anything larger is rejected at decode.
  final int vouchCap;

  /// The voucher's logical clock when it signed. Orders a vouch against a
  /// later revocation of it (§4) — the only ordering available with no
  /// synchronised time.
  final LogicalClock logicalClock;

  const VouchMessage({
    required this.voucheePubKey,
    required this.vouchIndex,
    required this.vouchCap,
    required this.logicalClock,
  });

  Uint8List encode() {
    return Uint8List.fromList(cbor.encode(CborList([
      CborBytes(voucheePubKey),
      CborSmallInt(vouchIndex),
      CborSmallInt(vouchCap),
      logicalClock.toCbor(),
    ])));
  }

  static BodyDecodeResult<VouchMessage> decode(List<int> bytes) {
    final list = BodyFields.readArray(bytes, 4);
    if (list == null) return const BodyDecodeError('expected a 4-field array');

    final vouchee =
        BodyFields.bytesOfLength(list[0], ClaimSignature.publicKeyLength);
    if (vouchee == null) {
      return const BodyDecodeError('voucheePubKey: wrong length');
    }

    final index = BodyFields.nonNegativeInt(list[1]);
    if (index == null || index < 1) {
      return const BodyDecodeError('vouchIndex: expected a positive integer');
    }

    final cap = BodyFields.nonNegativeInt(list[2]);
    if (cap == null || cap < 1) {
      return const BodyDecodeError('vouchCap: expected a positive integer');
    }
    if (cap > maxVouchCap) {
      return BodyDecodeError(
        'vouchCap: $cap exceeds the $maxVouchCap this device honours (§2.2)',
      );
    }
    if (index > cap) {
      return BodyDecodeError(
        'vouchIndex $index is past the vouch\'s own cap of $cap',
      );
    }

    final clock = BodyFields.clock(list[3]);
    if (clock == null) {
      return const BodyDecodeError('logicalClock: malformed');
    }

    return BodyDecodeOk(VouchMessage(
      voucheePubKey: Uint8List.fromList(vouchee),
      vouchIndex: index,
      vouchCap: cap,
      logicalClock: clock,
    ));
  }
}
