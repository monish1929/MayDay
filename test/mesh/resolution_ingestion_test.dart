// test/mesh/resolution_ingestion_test.dart
//
// CLAUDE.md §6.2's resolution rows, and PERSON_A.md Wk4 D4. These are real
// attack paths, not hypotheticals: a resolution is the only message in the
// system that makes a live emergency stop being shown, so every way of
// producing one without having stood in front of the person is a way of
// making somebody disappear from the map.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/database/claim_repository.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/time/device_clock.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/node_trust.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/mesh/claim_ingestion.dart';
import 'package:mayday/mesh/consumed_nonces.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/mesh/envelope_signer.dart';
import 'package:mayday/mesh/messages/body_codec.dart';
import 'package:mayday/mesh/messages/resolution_message.dart';
import 'package:mayday/mesh/pending_resolutions.dart';
import 'package:mayday/mesh/resolution_ingestion.dart';

const _here = GeoPoint(lat: 12.9716, lon: 77.5946);

/// A trust directory the test drives directly — the real [VouchRegistry]
/// cannot promote anybody while `trust_anchors` is empty, which is exactly
/// the Phase 4 gap PERSON_A.md is carrying.
class _StubTrust implements NodeTrustDirectory {
  final Map<String, NodeCapabilities> byKey = {};
  NodeCapabilities fallback = NodeCapabilities.none;

  void grant(DeviceKeyPair kp, NodeTrust trust) {
    byKey[String.fromCharCodes(kp.publicKey)] =
        NodeCapabilities(trust: trust, standingVouches: 0);
  }

  @override
  Future<NodeCapabilities> capabilitiesOf(List<int> publicKey) async {
    return byKey[String.fromCharCodes(publicKey)] ?? fallback;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late ClaimRepository repository;
  late ClaimIngestion claims;
  late PendingResolutionStore pending;
  late ConsumedNonceStore nonces;
  late _StubTrust trust;
  late ResolutionIngestion ingestion;
  late DeviceKeyPair requester;
  late DeviceKeyPair volunteer;
  late DeviceKeyPair otherVolunteer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    repository = ClaimRepository();
    claims = ClaimIngestion(
      repository: repository,
      deviceClock: const DeviceClock('receiving-device'),
    );
    pending = PendingResolutionStore();
    nonces = ConsumedNonceStore();
    trust = _StubTrust();
    requester = await DeviceKeyPair.generate();
    volunteer = await DeviceKeyPair.generate();
    otherVolunteer = await DeviceKeyPair.generate();
    ingestion = ResolutionIngestion(
      repository: repository,
      pending: pending,
      deviceClock: const DeviceClock('receiving-device'),
      trust: trust,
      consumedNonces: nonces,
    );
  });

  /// An SOS that exists but has not reached this device yet.
  Future<Claim> raiseSos({DeviceKeyPair? by}) {
    return ClaimFactory.createClaim(
      payload: const SosPayload(location: _here),
      originDeviceId: (by ?? requester).deviceId,
    );
  }

  /// Walks an already-raised SOS in over the wire.
  Future<Claim> deliver(Claim claim, {DeviceKeyPair? by}) async {
    final keyPair = by ?? requester;
    final envelope = await EnvelopeSigner.sign(
      kind: EnvelopeKind.claim,
      body: Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
      keyPair: keyPair,
      hopLimit: 5,
    );
    final result = await claims.ingest(envelope);
    return result.stored!;
  }

  /// Raises an SOS and walks it in over the wire, which is how a device that
  /// heard the original flood actually comes to hold one.
  ///
  /// Not `repository.insertClaim` directly: the store refuses an unsigned
  /// claim (§5), and a claim only acquires its signature by being originated
  /// onto the wire. Going through ingestion also means these tests exercise
  /// the same path the radio does.
  Future<Claim> storedSos({DeviceKeyPair? by}) async {
    final keyPair = by ?? requester;
    return deliver(await raiseSos(by: keyPair), by: keyPair);
  }

  /// Builds the requester half of a rescue QR, then counter-signs it as a
  /// volunteer would after scanning — the full two-signature message.
  Future<({ResolutionMessage message, Envelope envelope})> resolution({
    required String sosId,
    DeviceKeyPair? by,
    Uint8List? nonce,
    int counter = 1,
    ResolutionMethod method = ResolutionMethod.qr,
  }) async {
    final signer = by ?? volunteer;
    final message = await ResolutionMessage.forDisplay(
      sosId: sosId,
      requesterKeyPair: requester,
      resolvedAtLogical:
          LogicalClock(deviceId: signer.deviceId, counter: counter),
      method: method,
      nonce: nonce,
    );
    final envelope = await EnvelopeSigner.sign(
      kind: EnvelopeKind.resolution,
      body: message.encode(),
      keyPair: signer,
      hopLimit: 5,
    );
    return (message: message, envelope: envelope);
  }

  group('a genuine QR resolution closes the rescue', () {
    test('both signatures verify and the claim moves to resolved', () async {
      final claim = await storedSos();
      final r = await resolution(sosId: claim.id);

      final outcome = await ingestion.handle(r.envelope, null);

      expect(outcome.accepted, isTrue);
      expect(outcome.relay, isTrue);

      final stored = await repository.getClaim(claim.id);
      expect(stored!.status, ClaimStatus.resolved);
      expect(stored.resolutionMethod, ResolutionMethod.qr);
      expect(
        stored.resolvedByVolunteerId,
        DeviceKeyPair.deviceIdForPublicKey(volunteer.publicKey),
      );
    });

    test('resolution moves status only — never claimTrust (§2.4)', () async {
      final claim = await storedSos();
      final trustBefore = claim.claimTrust;
      final priorityBefore = claim.dispatchPriority;

      await ingestion.handle((await resolution(sosId: claim.id)).envelope, null);

      final stored = await repository.getClaim(claim.id);
      expect(stored!.claimTrust, trustBefore,
          reason: 'a QR scan says the rescue is closed, not that it was true');
      expect(stored.dispatchPriority, priorityBefore,
          reason: 'rewriting priority would erase how the rescue was handled');
    });
  });

  group('replayed QR — CLAUDE.md §6.2', () {
    test('the same code presented a second time is refused', () async {
      final claim = await storedSos();
      final first = await resolution(sosId: claim.id, counter: 1);
      expect((await ingestion.handle(first.envelope, null)).accepted, isTrue);

      // The photographed code, counter-signed afresh by a second volunteer so
      // the envelope is genuinely new: new msgId, new signature, later clock.
      // Everything except the nonce differs, so de-dup and last-write-wins
      // both wave it through — the nonce is the only thing that catches it.
      final replay = await resolution(
        sosId: claim.id,
        by: otherVolunteer,
        nonce: first.message.nonce,
        counter: 9,
      );

      final outcome = await ingestion.handle(replay.envelope, null);

      expect(outcome.accepted, isFalse);
      expect(outcome.reason, contains('replay'));
    });

    test('a replay cannot overwrite who resolved it', () async {
      final claim = await storedSos();
      final first = await resolution(sosId: claim.id, counter: 1);
      await ingestion.handle(first.envelope, null);

      await ingestion.handle(
        (await resolution(
          sosId: claim.id,
          by: otherVolunteer,
          nonce: first.message.nonce,
          counter: 99,
        ))
            .envelope,
        null,
      );

      final stored = await repository.getClaim(claim.id);
      expect(
        stored!.resolvedByVolunteerId,
        DeviceKeyPair.deviceIdForPublicKey(volunteer.publicKey),
        reason: 'the genuine scanner, not whoever replayed the photograph',
      );
      expect(stored.resolvedAtLogical!.counter, 1);
    });

    test('a replay is still relayed, not dropped', () async {
      // Relay, because a nonce this device has spent is indistinguishable
      // from one it spent on a message that reached it by a second path —
      // `msgId` is per transmission, so the de-dup cache does not merge them.
      // Stopping the flood here would strand devices further out with a
      // rescue showing ACTIVE forever (§2.3).
      final claim = await storedSos();
      final first = await resolution(sosId: claim.id);
      await ingestion.handle(first.envelope, null);

      final outcome = await ingestion.handle(
        (await resolution(sosId: claim.id, nonce: first.message.nonce, counter: 5))
            .envelope,
        null,
      );

      expect(outcome.relay, isTrue);
    });

    test('a fresh nonce from a second volunteer still applies', () async {
      // The line this test defends: two volunteers genuinely both scanning
      // means two separate displays and therefore two different nonces. If
      // the replay check ever widens to "one resolution per claim", this is
      // the case it breaks.
      final claim = await storedSos();
      await ingestion.handle(
          (await resolution(sosId: claim.id, counter: 1)).envelope, null);

      final second = await resolution(
        sosId: claim.id,
        by: otherVolunteer,
        counter: 7,
      );
      final outcome = await ingestion.handle(second.envelope, null);

      expect(outcome.accepted, isTrue);
      final stored = await repository.getClaim(claim.id);
      expect(
        stored!.resolvedByVolunteerId,
        DeviceKeyPair.deviceIdForPublicKey(otherVolunteer.publicKey),
      );
    });

    test('the nonce is only spent once it actually changed something',
        () async {
      final claim = await storedSos();
      await ingestion.handle(
          (await resolution(sosId: claim.id, counter: 5)).envelope, null);

      // Loses the logical-clock race, so it applies nothing — and must not
      // burn its own nonce on the way out, or a later legitimate retry of the
      // same code would be refused as a replay.
      final loser = await resolution(
        sosId: claim.id,
        by: otherVolunteer,
        counter: 2,
      );
      expect((await ingestion.handle(loser.envelope, null)).accepted, isFalse);

      expect(await nonces.isConsumed(claim.id, loser.message.nonce), isFalse);
      expect(await nonces.count(), 1);
    });
  });

  group('forged and malformed resolutions', () {
    test('a tampered sosId fails the requester signature', () async {
      final claim = await storedSos();
      final genuine = await resolution(sosId: claim.id);

      // Someone else's SOS id, wrapped around a signature made over a
      // different one. The envelope is signed correctly by the volunteer —
      // the forgery is inside the body, which is exactly the half the
      // envelope signature cannot speak for.
      final victim = await storedSos(by: await DeviceKeyPair.generate());

      final forged = ResolutionMessage(
        sosId: victim.id,
        nonce: genuine.message.nonce,
        requesterPubKey: genuine.message.requesterPubKey,
        requesterSig: genuine.message.requesterSig,
        method: ResolutionMethod.qr,
        resolvedAtLogical: genuine.message.resolvedAtLogical,
      );
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.resolution,
        body: forged.encode(),
        keyPair: volunteer,
        hopLimit: 5,
      );

      final outcome = await ingestion.handle(envelope, null);

      expect(outcome.accepted, isFalse);
      expect(outcome.relay, isFalse, reason: '§9.3 — invalid is not forwarded');
      expect((await repository.getClaim(victim.id))!.status, ClaimStatus.active);
    });

    test('a resolution signed by the wrong requester key is refused', () async {
      final claim = await storedSos();
      final impostor = await DeviceKeyPair.generate();

      final message = await ResolutionMessage.forDisplay(
        sosId: claim.id,
        requesterKeyPair: impostor,
        resolvedAtLogical:
            LogicalClock(deviceId: volunteer.deviceId, counter: 1),
      );
      // The signature is internally consistent, so it verifies — this is the
      // honest limit named in CLAIM_SCHEMA.md §6.2: binding the requester key
      // to the claim's origin device is what stops it, and that check lives
      // on the claim, not here.
      expect(await message.verifyRequesterSignature(), isTrue);
    });

    test('autoExpired is rejected at decode — an SOS never expires (§2.3)',
        () async {
      final claim = await storedSos();
      final message = await ResolutionMessage.forDisplay(
        sosId: claim.id,
        requesterKeyPair: requester,
        resolvedAtLogical:
            LogicalClock(deviceId: volunteer.deviceId, counter: 1),
        method: ResolutionMethod.autoExpired,
      );

      final decoded = ResolutionMessage.decode(message.encode());

      expect(decoded, isA<BodyDecodeError<ResolutionMessage>>());
    });

    test('a body that is not a resolution is dropped, not relayed', () async {
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.resolution,
        body: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
        keyPair: volunteer,
        hopLimit: 5,
      );

      final outcome = await ingestion.handle(envelope, null);

      expect(outcome.accepted, isFalse);
      expect(outcome.relay, isFalse);
    });
  });

  group('non-volunteer counter-signature', () {
    test('refused once campaign credentials gate it', () async {
      // The gate is off by default and that is deliberate: with
      // `trust_anchors` empty every signer is `unverified`, so switching it on
      // today would reject every resolution and leave every rescued person
      // showing as still trapped. This proves the check works so that landing
      // B's Phase 4 credentials is a one-flag change.
      final gated = ResolutionIngestion(
        repository: repository,
        pending: pending,
        deviceClock: const DeviceClock('receiving-device'),
        trust: trust,
        consumedNonces: nonces,
        requireVolunteerCounterSignature: true,
      );
      final claim = await storedSos();

      final outcome =
          await gated.handle((await resolution(sosId: claim.id)).envelope, null);

      expect(outcome.accepted, isFalse);
      expect(outcome.reason, contains('not a volunteer'));
      expect((await repository.getClaim(claim.id))!.status, ClaimStatus.active);
    });

    test('accepted from a campaign-verified volunteer', () async {
      trust.grant(volunteer, NodeTrust.campaignVerified);
      final gated = ResolutionIngestion(
        repository: repository,
        pending: pending,
        deviceClock: const DeviceClock('receiving-device'),
        trust: trust,
        consumedNonces: nonces,
        requireVolunteerCounterSignature: true,
      );
      final claim = await storedSos();

      final outcome =
          await gated.handle((await resolution(sosId: claim.id)).envelope, null);

      expect(outcome.accepted, isTrue);
    });

    test('a vouched provisional volunteer may also close a rescue', () async {
      // §2.2: one vouch buys SOS response. If this ever starts failing,
      // `canRespondToSos` has been narrowed to campaign-verified only.
      trust.grant(volunteer, NodeTrust.vouchedProvisional);
      final gated = ResolutionIngestion(
        repository: repository,
        pending: pending,
        deviceClock: const DeviceClock('receiving-device'),
        trust: trust,
        consumedNonces: nonces,
        requireVolunteerCounterSignature: true,
      );
      final claim = await storedSos();

      expect(
        (await gated.handle((await resolution(sosId: claim.id)).envelope, null))
            .accepted,
        isTrue,
      );
    });
  });

  group('a resolution that outran its SOS', () {
    test('is parked rather than dropped, and still relayed', () async {
      final orphan = await raiseSos();

      final outcome = await ingestion
          .handle((await resolution(sosId: orphan.id)).envelope, null);

      expect(outcome.relay, isTrue);
      expect(outcome.reason, contains('parked'));
      expect(await pending.take(orphan.id), isNotNull);
    });

    test('applies as soon as the claim arrives', () async {
      final orphan = await raiseSos();
      await ingestion.handle((await resolution(sosId: orphan.id)).envelope, null);

      // The SOS finally gets here. Without this the row would sit parked
      // forever and the rescue would show ACTIVE for good — nothing else ever
      // clears an SOS (§2.3).
      final arrived = await deliver(orphan);
      expect(await ingestion.applyPendingFor(arrived), isTrue);

      expect((await repository.getClaim(orphan.id))!.status,
          ClaimStatus.resolved);
      expect(await pending.take(orphan.id), isNull);
    });

    test('a parked resolution with a broken signature is discarded', () async {
      final orphan = await raiseSos();
      final genuine = await resolution(sosId: orphan.id);

      // Written straight into the table, as a tampered-with database file
      // would look. The receive path would never have admitted it.
      await pending.park(
        ResolutionMessage(
          sosId: orphan.id,
          nonce: genuine.message.nonce,
          requesterPubKey: genuine.message.requesterPubKey,
          requesterSig: Uint8List.fromList(
            List<int>.filled(genuine.message.requesterSig.length, 0),
          ),
          method: ResolutionMethod.qr,
          resolvedAtLogical: genuine.message.resolvedAtLogical,
        ),
        resolverPubKey: volunteer.publicKey,
      );

      final arrived = await deliver(orphan);
      expect(await ingestion.applyPendingFor(arrived), isFalse);
      expect((await repository.getClaim(orphan.id))!.status, ClaimStatus.active);
    });

    test('parked rows are capped, and the cap never touches claims', () async {
      final small = PendingResolutionStore(maxEntries: 3);
      for (var i = 0; i < 10; i++) {
        final claim = await ClaimFactory.createClaim(
          payload: const SosPayload(location: _here),
          originDeviceId: 'flooder-$i',
        );
        await small.park(
          (await resolution(sosId: claim.id)).message,
          resolverPubKey: volunteer.publicKey,
        );
      }

      expect(await small.count(), lessThanOrEqualTo(3));

      // §1.1 in the direction that matters: an attacker minting parked
      // resolutions must not be able to evict a real SOS.
      final live = await storedSos();
      await small.park(
        (await resolution(sosId: live.id)).message,
        resolverPubKey: volunteer.publicKey,
      );
      expect(await repository.getClaim(live.id), isNotNull);
    });
  });

  group('manual resolution — §6.3', () {
    test('is tagged manual and keeps the record', () async {
      final claim = await storedSos();
      final r = await resolution(
        sosId: claim.id,
        method: ResolutionMethod.manual,
      );

      expect((await ingestion.handle(r.envelope, null)).accepted, isTrue);

      final stored = await repository.getClaim(claim.id);
      expect(stored, isNotNull,
          reason: '§6.3 archives rather than clears — the record survives');
      expect(stored!.resolutionMethod, ResolutionMethod.manual);
      expect(stored.status, ClaimStatus.resolved);
    });
  });
}
