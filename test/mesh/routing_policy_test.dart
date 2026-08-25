// test/mesh/routing_policy_test.dart

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/mesh/envelope_signer.dart';
import 'package:mayday/mesh/routing_policy.dart';

const _here = GeoPoint(lat: 12.9716, lon: 77.5946);
const _policy = RoutingPolicy();

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DeviceKeyPair sender;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    sender = await DeviceKeyPair.generate();
  });

  /// Wraps a real claim for the wire, exactly as origination would.
  Future<Envelope> claimEnvelope(ClaimPayload payload) async {
    final claim = await ClaimFactory.createClaim(
      payload: payload,
      originDeviceId: sender.deviceId,
    );
    return EnvelopeSigner.sign(
      kind: EnvelopeKind.claim,
      body: Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
      keyPair: sender,
      hopLimit: 5,
    );
  }

  Future<Envelope> nonClaim(EnvelopeKind kind) {
    return EnvelopeSigner.sign(
      kind: kind,
      body: Uint8List.fromList([1, 2, 3]),
      keyPair: sender,
      hopLimit: 5,
    );
  }

  group('claim types', () {
    test('SOS floods', () async {
      final e = await claimEnvelope(const SosPayload(location: _here));
      expect(_policy.decide(e), RelayDecision.flood);
    });

    test('proxy SOS floods — the phone-less case still reaches everyone',
        () async {
      final e = await claimEnvelope(SosProxyPayload(
        location: _here,
        reporterDeviceId: sender.deviceId,
      ));
      expect(_policy.decide(e), RelayDecision.flood);
    });

    test('hazard floods — it routes people away from danger', () async {
      final e = await claimEnvelope(const HazardReportPayload(
        location: _here,
        hazardType: HazardType.flood,
        confirmationCount: 1,
      ));
      expect(_policy.decide(e), RelayDecision.flood);
    });

    test('resource is the only selective claim type', () async {
      final e = await claimEnvelope(const ResourcePayload(
        location: _here,
        category: ResourceCategory.foodWater,
        pledgedCount: 10,
        claimedReports: 0,
      ));
      expect(_policy.decide(e), RelayDecision.selective);
    });
  });

  group('non-claim kinds', () {
    test('a resolution floods like the SOS it answers', () async {
      expect(
        _policy.decide(await nonClaim(EnvelopeKind.resolution)),
        RelayDecision.flood,
      );
    });

    test('revocation floods — it has to outrun the vouch it cancels',
        () async {
      expect(
        _policy.decide(await nonClaim(EnvelopeKind.revocation)),
        RelayDecision.flood,
      );
    });

    test('time gossip is never relayed', () async {
      // It is evidence about the two devices that met, not about the mesh.
      // Forwarding it would let one skewed clock look like many observations.
      expect(
        _policy.decide(await nonClaim(EnvelopeKind.timeGossip)),
        RelayDecision.doNotRelay,
      );
    });
  });

  group('unclassifiable claims fail toward delivery', () {
    test('a claim body this version cannot parse is still flooded', () async {
      final e = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: Uint8List.fromList([0xff, 0xff, 0xff]),
        keyPair: sender,
        hopLimit: 5,
      );

      // Signature already proved this is well-formed and from a real device;
      // we simply cannot classify it. Dropping it would silently stop a future
      // claim type from propagating — and if it is an SOS, §1.1 says the
      // cautious guess is the wrong one to make.
      expect(RoutingPolicy.peekClaimType(e.body), isNull);
      expect(_policy.decide(e), RelayDecision.flood);
    });
  });

  group('hop limits', () {
    // The absolute values are provisional (CLAUDE.md §8, pending a walked 3b
    // run). The ORDERING is the design decision, and that is what is asserted
    // here — this test should survive the numbers being replaced.
    test('SOS travels furthest, resource least', () {
      expect(
        _policy.initialHopLimitFor(ClaimType.sos),
        greaterThan(_policy.initialHopLimitFor(ClaimType.hazardReport)),
      );
      expect(
        _policy.initialHopLimitFor(ClaimType.hazardReport),
        greaterThan(_policy.initialHopLimitFor(ClaimType.resource)),
      );
    });

    test('proxy SOS gets the same reach as a first-person SOS', () {
      expect(
        _policy.initialHopLimitFor(ClaimType.sosProxy),
        _policy.initialHopLimitFor(ClaimType.sos),
      );
    });
  });
}
