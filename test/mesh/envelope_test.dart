// test/mesh/envelope_test.dart

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/models/logical_clock.dart';

Uint8List _fixedBytes(int length, int fill) =>
    Uint8List.fromList(List<int>.filled(length, fill));

Envelope _sampleEnvelope({
  required EnvelopeKind kind,
  Uint8List? body,
  Uint8List? msgId,
}) {
  return Envelope(
    v: Envelope.protocolVersion,
    msgId: msgId ?? Envelope.generateMsgId(),
    hopLimit: 5,
    kind: kind,
    body: body ?? _fixedBytes(4, 0xAB),
    originPubKey: _fixedBytes(Envelope.publicKeyLength, 0xEE),
    originSig: _fixedBytes(Envelope.signatureLength, 0xCD),
  );
}

void main() {
  group('Envelope CBOR round-trip', () {
    for (final kind in EnvelopeKind.values) {
      test('round-trips byte-identically for kind=${kind.name}', () {
        final envelope = _sampleEnvelope(kind: kind);
        final encoded = envelope.encode();

        final result = Envelope.decode(encoded);
        expect(result, isA<EnvelopeDecodeOk>());
        final decoded = (result as EnvelopeDecodeOk).envelope;

        expect(decoded.encode(), equals(encoded));
        expect(decoded.v, envelope.v);
        expect(decoded.msgId, envelope.msgId);
        expect(decoded.hopLimit, envelope.hopLimit);
        expect(decoded.kind, envelope.kind);
        expect(decoded.body, envelope.body);
        expect(decoded.originSig, envelope.originSig);
      });
    }
  });

  group('msgId freshness', () {
    test('same Claim body encoded twice → different msgId, identical body', () {
      final claim = Claim(
        id: 'claim-1',
        type: ClaimType.hazardReport,
        originDeviceId: 'device-1',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: const LogicalClock(deviceId: 'device-1', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 5,
        createdAtLogical: const LogicalClock(deviceId: 'device-1', counter: 1),
        payload: HazardReportPayload(
          location: const GeoPoint(lat: 12.9716, lon: 77.5946),
          hazardType: HazardType.flood,
          confirmationCount: 1,
        ),
      );
      final body = Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor()));

      final first = _sampleEnvelope(kind: EnvelopeKind.claim, body: body);
      final second = _sampleEnvelope(kind: EnvelopeKind.claim, body: body);

      expect(first.msgId, isNot(equals(second.msgId)));
      expect(first.body, equals(second.body));
    });
  });

  group('malformed input never throws', () {
    test('random garbage bytes → typed failure, not an exception', () {
      final garbage = _fixedBytes(10, 0xFF);
      final result = Envelope.decode(garbage);
      expect(result, isA<EnvelopeDecodeError>());
    });

    test('empty bytes → typed failure', () {
      final result = Envelope.decode(Uint8List(0));
      expect(result, isA<EnvelopeDecodeError>());
    });

    test('valid CBOR but wrong shape (a plain string) → typed failure', () {
      final bytes = Uint8List.fromList(cbor.encode(CborString('not an envelope')));
      final result = Envelope.decode(bytes);
      expect(result, isA<EnvelopeDecodeError>());
    });

    test('valid CBOR list, wrong field count → typed failure', () {
      final bytes = Uint8List.fromList(cbor.encode(CborList([CborSmallInt(1), CborSmallInt(2)])));
      final result = Envelope.decode(bytes);
      expect(result, isA<EnvelopeDecodeError>());
    });

    test('unknown kind value → typed failure', () {
      final bytes = Uint8List.fromList(cbor.encode(CborList([
        CborSmallInt(1),
        CborBytes(_fixedBytes(Envelope.msgIdLength, 1)),
        CborSmallInt(5),
        CborSmallInt(99), // no such EnvelopeKind
        CborBytes(_fixedBytes(4, 1)),
        CborBytes(_fixedBytes(Envelope.publicKeyLength, 1)),
        CborBytes(_fixedBytes(Envelope.signatureLength, 1)),
      ])));
      final result = Envelope.decode(bytes);
      expect(result, isA<EnvelopeDecodeError>());
    });

    test('wrong-length msgId → typed failure', () {
      final bytes = Uint8List.fromList(cbor.encode(CborList([
        CborSmallInt(1),
        CborBytes(_fixedBytes(4, 1)), // should be 16
        CborSmallInt(5),
        CborSmallInt(0),
        CborBytes(_fixedBytes(4, 1)),
        CborBytes(_fixedBytes(Envelope.publicKeyLength, 1)),
        CborBytes(_fixedBytes(Envelope.signatureLength, 1)),
      ])));
      final result = Envelope.decode(bytes);
      expect(result, isA<EnvelopeDecodeError>());
    });
  });

  group('signingPayload excludes hopLimit and msgId', () {
    test('mutating hopLimit and msgId leaves signingPayload unchanged', () {
      final body = _fixedBytes(20, 0x11);
      final a = Envelope(
        v: 1,
        msgId: Envelope.generateMsgId(),
        hopLimit: 5,
        kind: EnvelopeKind.claim,
        body: body,
        originPubKey: _fixedBytes(Envelope.publicKeyLength, 0xEE),
        originSig: _fixedBytes(Envelope.signatureLength, 0),
      );
      // Simulate a relay hop: fresh msgId is not applicable here (msgId
      // itself is per-transmission, not mutated in place), but hopLimit
      // decrements exactly like a real relay would do.
      final b = Envelope(
        v: a.v,
        msgId: Envelope.generateMsgId(),
        hopLimit: a.hopLimit - 1,
        kind: a.kind,
        body: a.body,
        originPubKey: a.originPubKey,
        originSig: a.originSig,
      );

      expect(a.signingPayload(), equals(b.signingPayload()));
    });
  });

  group('real claim size measurements (§9.2 budget: target <=400B, ceiling 512B)', () {
    Uint8List envelopeBytesFor(Claim claim) {
      final body = Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor()));
      final envelope = _sampleEnvelope(kind: EnvelopeKind.claim, body: body);
      return envelope.encode();
    }

    test('SOS', () {
      final claim = Claim(
        id: 'sos-1',
        type: ClaimType.sos,
        originDeviceId: 'device-aaaaaaaaaaaaaaaa',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: const LogicalClock(deviceId: 'device-aaaaaaaaaaaaaaaa', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 5,
        createdAtLogical: const LogicalClock(deviceId: 'device-aaaaaaaaaaaaaaaa', counter: 1),
        payload: SosPayload(
          location: const GeoPoint(lat: 12.9716, lon: 77.5946),
          headcount: HeadcountBucket.sixToFifteen,
        ),
      );
      final size = envelopeBytesFor(claim).length;
      // ignore: avoid_print
      print('SOS envelope size: $size bytes');
      expect(size, lessThanOrEqualTo(512));
    });

    test('SOS_PROXY', () {
      final claim = Claim(
        id: 'sosproxy-1',
        type: ClaimType.sosProxy,
        originDeviceId: 'device-bbbbbbbbbbbbbbbb',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: const LogicalClock(deviceId: 'device-bbbbbbbbbbbbbbbb', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 5,
        createdAtLogical: const LogicalClock(deviceId: 'device-bbbbbbbbbbbbbbbb', counter: 1),
        payload: SosProxyPayload(
          location: const GeoPoint(lat: 12.9716, lon: 77.5946),
          headcount: HeadcountBucket.twoToFive,
          reporterDeviceId: 'device-cccccccccccccccc',
        ),
      );
      final size = envelopeBytesFor(claim).length;
      // ignore: avoid_print
      print('SOS_PROXY envelope size: $size bytes');
      expect(size, lessThanOrEqualTo(512));
    });

    test('HAZARD_REPORT', () {
      final claim = Claim(
        id: 'hazard-1',
        type: ClaimType.hazardReport,
        originDeviceId: 'device-dddddddddddddddd',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: const LogicalClock(deviceId: 'device-dddddddddddddddd', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 5,
        createdAtLogical: const LogicalClock(deviceId: 'device-dddddddddddddddd', counter: 1),
        payload: HazardReportPayload(
          location: const GeoPoint(lat: 12.9716, lon: 77.5946),
          hazardType: HazardType.structuralDamage,
          confirmationCount: 3,
        ),
      );
      final size = envelopeBytesFor(claim).length;
      // ignore: avoid_print
      print('HAZARD_REPORT envelope size: $size bytes');
      expect(size, lessThanOrEqualTo(512));
    });

    test('RESOURCE', () {
      final claim = Claim(
        id: 'resource-1',
        type: ClaimType.resource,
        originDeviceId: 'device-eeeeeeeeeeeeeeee',
        originSequence: 1,
        originSignature: Uint8List(64),
        logicalClock: const LogicalClock(deviceId: 'device-eeeeeeeeeeeeeeee', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 5,
        createdAtLogical: const LogicalClock(deviceId: 'device-eeeeeeeeeeeeeeee', counter: 1),
        payload: ResourcePayload(
          location: const GeoPoint(lat: 12.9716, lon: 77.5946),
          category: ResourceCategory.foodWater,
          pledgedCount: 50,
          claimedReports: 20,
        ),
      );
      final size = envelopeBytesFor(claim).length;
      // ignore: avoid_print
      print('RESOURCE envelope size: $size bytes');
      expect(size, lessThanOrEqualTo(512));
    });
  });
}
