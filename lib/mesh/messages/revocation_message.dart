// lib/mesh/messages/revocation_message.dart

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../data/models/logical_clock.dart';
import '../../identity/node_trust.dart';
import '../../identity/signature.dart';
import 'body_codec.dart';

/// `kind: 4` — withdrawing a vouch, PERSON_A.md Wk4 D2 and
/// MAYDAY_PROJECT_CONTEXT.md §2.2.
///
/// "A signed revocation message propagates like any other claim and overrides
/// the vouch. Devices apply the most recent valid revocation." v1 of the
/// design had no revocation at all, which meant a single bad vouch was
/// permanent across the entire mesh forever.
///
/// **Only the original voucher may revoke.** The revoker's key is the
/// envelope's `originPubKey`, and `VouchRegistry` refuses a revocation whose
/// signer is not the device that signed the vouch. Without that rule anyone
/// could strip any volunteer of their status by shouting one 100-byte message
/// into the mesh — a denial-of-service against the responders.
///
/// **Revocation is not the droppable class.** `RoutingPolicy` floods it,
/// because a revocation that stalls while the vouch it cancels keeps
/// travelling is worse than either message alone.
class RevocationMessage {
  /// Raw Ed25519 public key whose vouch is being withdrawn.
  final Uint8List revokedPubKey;

  /// Advisory only — every reason revokes. See [RevocationReason].
  final RevocationReason reason;

  /// The revoker's logical clock when it signed.
  ///
  /// This is what "most recent valid revocation wins" is measured against
  /// (§4): a revocation cancels vouches at or below its counter, so a genuine
  /// re-vouch signed later still stands. Ordering by wall clock would let a
  /// device with a skewed clock silently un-revoke itself.
  final LogicalClock logicalClock;

  const RevocationMessage({
    required this.revokedPubKey,
    required this.reason,
    required this.logicalClock,
  });

  Uint8List encode() {
    return Uint8List.fromList(cbor.encode(CborList([
      CborBytes(revokedPubKey),
      CborSmallInt(reason.index),
      logicalClock.toCbor(),
    ])));
  }

  static BodyDecodeResult<RevocationMessage> decode(List<int> bytes) {
    final list = BodyFields.readArray(bytes, 3);
    if (list == null) return const BodyDecodeError('expected a 3-field array');

    final revoked =
        BodyFields.bytesOfLength(list[0], ClaimSignature.publicKeyLength);
    if (revoked == null) {
      return const BodyDecodeError('revokedPubKey: wrong length');
    }

    final reasonIndex =
        BodyFields.enumIndex(list[1], RevocationReason.values.length);
    if (reasonIndex == null) {
      return const BodyDecodeError('reason: not a RevocationReason');
    }

    final clock = BodyFields.clock(list[2]);
    if (clock == null) {
      return const BodyDecodeError('logicalClock: malformed');
    }

    return BodyDecodeOk(RevocationMessage(
      revokedPubKey: Uint8List.fromList(revoked),
      reason: RevocationReason.values[reasonIndex],
      logicalClock: clock,
    ));
  }
}
