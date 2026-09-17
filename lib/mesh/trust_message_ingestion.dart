// lib/mesh/trust_message_ingestion.dart

import 'dart:typed_data';

import '../data/time/device_clock.dart';
import '../identity/node_trust.dart';
import '../identity/vouch_registry.dart';
import 'envelope.dart';
import 'message_handler.dart';
import 'messages/body_codec.dart';
import 'messages/revocation_message.dart';
import 'messages/vouch_message.dart';
import 'relay_queue.dart';

/// Applies `kind: 3` vouches — PERSON_A.md Wk4 D1.
///
/// The envelope already proved that whoever holds `originPubKey` signed these
/// bytes. What this adds is the two things a signature cannot say:
///
/// - **the signer was allowed to vouch at all** (campaign-verified only —
///   provisional nodes cannot vouch, MAYDAY_PROJECT_CONTEXT.md §2.2), and
/// - **the vouch fits inside the signer's cap of five**, which travels inside
///   the signed message so any device can check it with nothing to ask.
///
/// Both live in [VouchRegistry], because both are answers about accumulated
/// state rather than about this one message.
class VouchIngestion implements MessageHandler {
  final VouchRegistry registry;
  final DeviceClock deviceClock;

  VouchIngestion({required this.registry, required this.deviceClock});

  @override
  Future<MessageOutcome> handle(Envelope envelope, RelayTarget? from) async {
    final decoded = VouchMessage.decode(envelope.body);
    if (decoded is BodyDecodeError<VouchMessage>) {
      return MessageOutcome.dropped('vouch: ${decoded.reason}');
    }
    final vouch = (decoded as BodyDecodeOk<VouchMessage>).body;

    await deviceClock.observeReceive(vouch.logicalClock);

    final result = await registry.recordVouch(
      voucherPubKey: envelope.originPubKey,
      voucherSig: envelope.originSig,
      vouch: vouch,
    );

    if (result.applied) return const MessageOutcome.acceptedAndRelay();

    // **Rejected here, but still relayed** — and the distinction is the point
    // of a web of trust with no server in it. This device refused the vouch
    // because of what *this device* knows: most often that it has never heard
    // of the voucher, so it cannot see them as campaign-verified. A device
    // three hops on may hold that anchor and be able to act on the very same
    // message. Refusing to forward would make each phone's ignorance
    // contagious.
    //
    // The message is well-formed and correctly signed either way — it is not
    // the §9.3 "invalid, do not relay" case, which is about content a
    // signature cannot vouch for.
    return MessageOutcome.relayOnly('vouch not applied: ${result.rejection?.name}');
  }
}

/// Applies `kind: 4` revocations — PERSON_A.md Wk4 D2.
///
/// A revocation has to be able to outrun the vouch it cancels, which is why
/// `RoutingPolicy` floods it rather than putting it in the droppable class.
/// The rule that keeps it from becoming a weapon is in [VouchRegistry]: only
/// the original voucher may revoke their own vouch.
class RevocationIngestion implements MessageHandler {
  final VouchRegistry registry;
  final DeviceClock deviceClock;

  RevocationIngestion({required this.registry, required this.deviceClock});

  @override
  Future<MessageOutcome> handle(Envelope envelope, RelayTarget? from) async {
    final decoded = RevocationMessage.decode(envelope.body);
    if (decoded is BodyDecodeError<RevocationMessage>) {
      return MessageOutcome.dropped('revocation: ${decoded.reason}');
    }
    final revocation = (decoded as BodyDecodeOk<RevocationMessage>).body;

    await deviceClock.observeReceive(revocation.logicalClock);

    final result = await registry.recordRevocation(
      revokerPubKey: envelope.originPubKey,
      revocation: revocation,
    );

    if (result.applied) return const MessageOutcome.acceptedAndRelay();

    // Relayed for the same reason a rejected vouch is, and more urgently: the
    // commonest rejection here is `unknownVouch`, meaning the revocation
    // arrived somewhere the vouch never reached. Somebody further out holds
    // that vouch and needs this message. A revocation that stops at the first
    // device that cannot use it is a revoked volunteer who stays trusted
    // across most of the mesh.
    return MessageOutcome.relayOnly(
      'revocation not applied: ${result.rejection?.name}',
    );
  }
}

/// Signs outgoing vouches and revocations.
///
/// Kept beside the handlers rather than in `identity/` so the wire-format
/// half of Phase 4 stays in one place: `identity/` owns keys and node trust,
/// `mesh/` owns what those look like as messages (PERSON_A.md Wk4, "my share:
/// vouch and revocation as message kinds").
class TrustMessageFactory {
  TrustMessageFactory._();

  /// Builds the body of a vouch for [voucheePubKey].
  ///
  /// Deliberately does **not** check whether this device is allowed to vouch.
  /// That check belongs at the point where a person taps the button — a
  /// factory that silently produced nothing would look like a bug in the UI.
  /// [VouchRegistry.capabilitiesOf] on this device's own key is the call to
  /// make first; `canVouch` is the answer.
  static Future<VouchMessage> vouchFor({
    required List<int> voucheePubKey,
    required int vouchIndex,
    required DeviceClock deviceClock,
    int vouchCap = VouchMessage.maxVouchCap,
  }) async {
    return VouchMessage(
      voucheePubKey: Uint8List.fromList(voucheePubKey),
      vouchIndex: vouchIndex,
      vouchCap: vouchCap,
      logicalClock: await deviceClock.tickForSend(),
    );
  }

  /// Builds the body of a revocation for [revokedPubKey].
  ///
  /// The caller must be the device that signed the original vouch — every
  /// receiver enforces that (see [VouchRegistry.recordRevocation]), so a
  /// revocation signed by anyone else is bytes on the radio and nothing more.
  static Future<RevocationMessage> revoke({
    required List<int> revokedPubKey,
    required RevocationReason reason,
    required DeviceClock deviceClock,
  }) async {
    return RevocationMessage(
      revokedPubKey: Uint8List.fromList(revokedPubKey),
      reason: reason,
      logicalClock: await deviceClock.tickForSend(),
    );
  }
}
