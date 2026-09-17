// test/identity/vouch_registry_test.dart
//
// The web of trust — MAYDAY_PROJECT_CONTEXT.md §2.2, PERSON_A.md Wk4 D1–D2,
// and CLAUDE.md §4.5's `identity/` checklist:
//
//   - provisional (vouched) nodes cannot vouch for others
//   - the vouch cap is enforced and carried inside the signed vouch
//   - revocation propagates and overrides
//
// **Everything here is inert in a real build today**, and that is the point of
// testing it now. `trust_anchors` is empty in every build — issuing campaign
// credentials is B's Phase 4 work — so no device is campaign-verified and no
// vouch is accepted anywhere. These tests seed an anchor directly, which is
// the one thing a device cannot do for itself, and then exercise the rules
// that will govern the moment credentials land.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/node_trust.dart';
import 'package:mayday/identity/vouch_registry.dart';
import 'package:mayday/mesh/messages/revocation_message.dart';
import 'package:mayday/mesh/messages/vouch_message.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late VouchRegistry registry;
  late DeviceKeyPair anchor;
  late DeviceKeyPair alice;
  late DeviceKeyPair bob;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    registry = VouchRegistry();
    anchor = await DeviceKeyPair.generate();
    alice = await DeviceKeyPair.generate();
    bob = await DeviceKeyPair.generate();
  });

  /// One vouch from [by] for [forWhom], as the wire would deliver it.
  Future<TrustWriteResult> vouch(
    DeviceKeyPair by,
    DeviceKeyPair forWhom, {
    int index = 1,
    int counter = 1,
    int cap = VouchMessage.maxVouchCap,
  }) {
    return registry.recordVouch(
      voucherPubKey: by.publicKey,
      // The envelope's originSig in real life. Kept in the row so a stored
      // vouch stays independently checkable without the envelope.
      voucherSig: List<int>.filled(64, 0x01),
      vouch: VouchMessage(
        voucheePubKey: forWhom.publicKey,
        vouchIndex: index,
        vouchCap: cap,
        logicalClock:
            LogicalClock(deviceId: by.deviceId, counter: counter),
      ),
    );
  }

  Future<TrustWriteResult> revoke(
    DeviceKeyPair by,
    DeviceKeyPair whom, {
    int counter = 2,
    RevocationReason reason = RevocationReason.withdrawn,
  }) {
    return registry.recordRevocation(
      revokerPubKey: by.publicKey,
      revocation: RevocationMessage(
        revokedPubKey: whom.publicKey,
        reason: reason,
        logicalClock:
            LogicalClock(deviceId: by.deviceId, counter: counter),
      ),
    );
  }

  group('nothing is trusted by default', () {
    test('an unknown key is unverified with no vouches', () async {
      final caps = await registry.capabilitiesOf(alice.publicKey);

      expect(caps.trust, NodeTrust.unverified);
      expect(caps.isVolunteer, isFalse);
      expect(caps.canVouch, isFalse);
      expect(caps.canPledgeResources, isFalse);
    });

    test('with no trust anchor, even a well-formed vouch is refused',
        () async {
      // The state every build ships in today. Rejecting is the correct
      // direction — nobody becomes trusted by accident — but it does mean the
      // whole of Phase 4 is untestable on hardware until B's credentials land.
      final result = await vouch(anchor, alice);

      expect(result.applied, isFalse);
      expect(result.rejection, TrustWriteRejection.voucherNotVerified);
    });
  });

  group('vouching — §2.2', () {
    setUp(() async {
      await registry.addTrustAnchor(anchor.publicKey, label: 'campaign desk');
    });

    test('a campaign-verified device is a volunteer that may vouch', () async {
      final caps = await registry.capabilitiesOf(anchor.publicKey);

      expect(caps.trust, NodeTrust.campaignVerified);
      expect(caps.canVouch, isTrue);
      expect(caps.canPledgeResources, isTrue);
    });

    test('one vouch makes someone a provisional volunteer', () async {
      expect((await vouch(anchor, alice)).applied, isTrue);

      final caps = await registry.capabilitiesOf(alice.publicKey);
      expect(caps.trust, NodeTrust.vouchedProvisional);
      expect(caps.isVolunteer, isTrue);
      expect(caps.canRespondToSos, isTrue);
    });

    test('a provisional volunteer CANNOT vouch for anyone', () async {
      // The single rule that bounds the blast radius of one stolen phone.
      // Without it: a compromised key mints a provisional volunteer, who
      // mints five more, and every device in the mesh believes all of them.
      await vouch(anchor, alice);

      final result = await vouch(alice, bob);

      expect(result.applied, isFalse);
      expect(result.rejection, TrustWriteRejection.voucherNotVerified);
      expect((await registry.capabilitiesOf(bob.publicKey)).isVolunteer,
          isFalse);
    });

    test('a device cannot vouch for itself', () async {
      final result = await vouch(anchor, anchor);

      expect(result.applied, isFalse);
      expect(result.rejection, TrustWriteRejection.selfVouch);
    });

    test('the cap of five is enforced by the receiver, not the sender',
        () async {
      // "Carried inside the signed vouch so any device can check it
      // independently" — but a voucher signing its own cap is exactly the
      // party with a reason to lie, so the receiver counts for itself.
      final vouchees = <DeviceKeyPair>[];
      for (var i = 0; i < VouchMessage.maxVouchCap; i++) {
        final person = await DeviceKeyPair.generate();
        vouchees.add(person);
        expect((await vouch(anchor, person, index: i + 1, counter: i + 1))
            .applied, isTrue);
      }

      final sixth = await DeviceKeyPair.generate();
      final result =
          await vouch(anchor, sixth, index: 5, counter: 99);

      expect(result.applied, isFalse);
      expect(result.rejection, TrustWriteRejection.vouchCapExceeded);
      expect((await registry.capabilitiesOf(sixth.publicKey)).isVolunteer,
          isFalse);

      // The first five keep their standing — the cap turns away the newcomer,
      // it does not invalidate everyone.
      for (final person in vouchees) {
        expect((await registry.capabilitiesOf(person.publicKey)).isVolunteer,
            isTrue);
      }
    });

    test('re-sending the same vouch does not consume the cap twice', () async {
      // The primary key is (voucher, vouchee) precisely so a vouch arriving
      // by three different mesh paths is still one vouch.
      await vouch(anchor, alice, counter: 1);
      await vouch(anchor, alice, counter: 1);
      await vouch(anchor, alice, counter: 1);

      for (var i = 0; i < VouchMessage.maxVouchCap - 1; i++) {
        final person = await DeviceKeyPair.generate();
        expect((await vouch(anchor, person, index: i + 2, counter: i + 2))
            .applied, isTrue);
      }

      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isTrue);
    });

    test('resource pledging needs two independent campaign-verified vouches',
        () async {
      // §2.2 gates the spam-sensitive power behind a higher bar than SOS
      // response. See NodeCapabilities.canPledgeResources for the documented
      // drift this expresses as a capability rather than a fourth enum value.
      final secondAnchor = await DeviceKeyPair.generate();
      await registry.addTrustAnchor(secondAnchor.publicKey);

      await vouch(anchor, alice, counter: 1);
      expect(
        (await registry.capabilitiesOf(alice.publicKey)).canPledgeResources,
        isFalse,
        reason: 'one vouch buys SOS response, not resource authority',
      );

      await vouch(secondAnchor, alice, counter: 1);
      expect(
        (await registry.capabilitiesOf(alice.publicKey)).canPledgeResources,
        isTrue,
      );
    });
  });

  group('revocation — §2.2, PERSON_A.md Wk4 D2', () {
    setUp(() async {
      await registry.addTrustAnchor(anchor.publicKey);
      await vouch(anchor, alice, counter: 1);
    });

    test('overrides the vouch it cancels', () async {
      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isTrue);

      expect((await revoke(anchor, alice, counter: 2)).applied, isTrue);

      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isFalse,
          reason: 'a revoked volunteer must stop being one everywhere');
    });

    test('every reason revokes — the reason is advisory only', () async {
      for (final reason in RevocationReason.values) {
        await DatabaseHelper.instance.resetForTest();
        registry = VouchRegistry();
        await registry.addTrustAnchor(anchor.publicKey);
        await vouch(anchor, alice, counter: 1);

        await revoke(anchor, alice, counter: 2, reason: reason);

        expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
            isFalse,
            reason: 'a revocation that only sometimes revoked would be worse '
                'than none at all');
      }
    });

    test('only the original voucher may revoke', () async {
      // Otherwise anyone strips any volunteer of their status by shouting one
      // 100-byte message into the mesh — a denial of service against exactly
      // the people responding.
      final attacker = await DeviceKeyPair.generate();
      await registry.addTrustAnchor(attacker.publicKey);

      final result = await revoke(attacker, alice, counter: 50);

      expect(result.applied, isFalse);
      expect(result.rejection, TrustWriteRejection.notTheOriginalVoucher);
      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isTrue);
    });

    test('a revocation for a vouch nobody here holds is refused', () async {
      final stranger = await DeviceKeyPair.generate();

      final result = await revoke(anchor, stranger, counter: 5);

      expect(result.applied, isFalse);
      expect(result.rejection, TrustWriteRejection.unknownVouch);
    });

    test('a later re-vouch outranks an earlier revocation (§4)', () async {
      // Ordering is by logical clock, never a wall clock: a device with a
      // skewed clock must not be able to silently un-revoke itself.
      await revoke(anchor, alice, counter: 2);
      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isFalse);

      expect((await vouch(anchor, alice, counter: 9)).applied, isTrue);

      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isTrue,
          reason: 'people come back — a revocation is not a permanent ban');
    });

    test('revoking the voucher strips those it vouched for', () async {
      // The web is only as good as its roots. If a campaign-verified key is
      // revoked, the provisional volunteers hanging off it cannot keep
      // standing on it.
      final secondAnchor = await DeviceKeyPair.generate();
      await registry.addTrustAnchor(secondAnchor.publicKey);
      await vouch(anchor, alice, counter: 1);

      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isTrue);
      expect((await revoke(anchor, alice, counter: 7)).applied, isTrue);
      expect((await registry.capabilitiesOf(alice.publicKey)).isVolunteer,
          isFalse);
    });
  });
}
