// test/mesh/message_codecs_test.dart
//
// The body codecs for CLAIM_SCHEMA.md §9.1 kinds 2–6.
//
// Every one of these decodes bytes a stranger's phone put on the air, so the
// contract they share is worth stating once: **nothing here throws, ever.** A
// malformed body is an expected message from an unknown device, not a bug
// (§9.3), and a decoder that threw would turn a hostile packet into a crash
// on the receive path — a one-frame denial of service against a rescue radio.

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/node_trust.dart';
import 'package:mayday/identity/signature.dart';
import 'package:mayday/mesh/messages/beacon_message.dart';
import 'package:mayday/mesh/messages/body_codec.dart';
import 'package:mayday/mesh/messages/resolution_message.dart';
import 'package:mayday/mesh/messages/revocation_message.dart';
import 'package:mayday/mesh/messages/time_gossip_message.dart';
import 'package:mayday/mesh/messages/vouch_message.dart';

const _clock = LogicalClock(deviceId: 'device-a', counter: 7);

Uint8List _bytes(int length, [int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

Uint8List _cborList(List<CborValue> items) =>
    Uint8List.fromList(cbor.encode(CborList(items)));

/// Every shape of input a radio can hand a decoder that is not a valid body.
const _garbage = <String, List<int>>{
  'empty': <int>[],
  'not cbor at all': [0xff, 0xfe, 0xfd, 0xfc],
  'truncated': [0x84, 0x01],
};

void main() {
  group('shared field readers refuse what a signature cannot catch', () {
    test('a byte string of the wrong length is not a key', () {
      // Not pedantry: an Ed25519 public key that is not 32 bytes cannot verify
      // anything, and admitting one means carrying a value that looks like a
      // key through every layer downstream.
      expect(BodyFields.bytesOfLength(CborBytes(_bytes(31)), 32), isNull);
      expect(BodyFields.bytesOfLength(CborBytes(_bytes(33)), 32), isNull);
      expect(BodyFields.bytesOfLength(CborBytes(_bytes(32)), 32), isNotNull);
    });

    test('an enum index past the end of the enum is refused', () {
      expect(BodyFields.enumIndex(const CborSmallInt(0), 3), 0);
      expect(BodyFields.enumIndex(const CborSmallInt(2), 3), 2);
      expect(BodyFields.enumIndex(const CborSmallInt(3), 3), isNull);
      expect(BodyFields.enumIndex(const CborSmallInt(999), 3), isNull);
    });

    test('free text is bounded — a stranger chooses its length', () {
      expect(BodyFields.text(CborString('x' * 64), maxLength: 64), isNotNull);
      expect(BodyFields.text(CborString('x' * 65), maxLength: 64), isNull);
      expect(BodyFields.text(CborString(''), maxLength: 64), isNull);
    });

    test('an array of the wrong arity is refused before any field is read',
        () {
      final three = _cborList(const [
        CborSmallInt(1),
        CborSmallInt(2),
        CborSmallInt(3),
      ]);
      expect(BodyFields.readArray(three, 3), isNotNull);
      expect(BodyFields.readArray(three, 2), isNull);
      expect(BodyFields.readArray(three, 4), isNull);
    });

    test('a CBOR map is not a positional array', () {
      // The kinds use positional arrays, not maps, because every key name is
      // bytes against the 400-byte envelope budget. A map arriving where an
      // array is expected is a different protocol, not a lenient one.
      final map = Uint8List.fromList(
        cbor.encode(CborMap({const CborSmallInt(0): const CborSmallInt(1)})),
      );
      expect(BodyFields.readArray(map, 1), isNull);
    });
  });

  group('kind 2 — resolution', () {
    ResolutionMessage sample({ResolutionMethod method = ResolutionMethod.qr}) {
      return ResolutionMessage(
        sosId: 'a' * 64,
        nonce: _bytes(ResolutionMessage.nonceLength),
        requesterPubKey: _bytes(ClaimSignature.publicKeyLength, 0x22),
        requesterSig: _bytes(ClaimSignature.signatureLength, 0x33),
        method: method,
        resolvedAtLogical: _clock,
      );
    }

    test('round-trips', () {
      final decoded = ResolutionMessage.decode(sample().encode());

      expect(decoded, isA<BodyDecodeOk<ResolutionMessage>>());
      final body = (decoded as BodyDecodeOk<ResolutionMessage>).body;
      expect(body.sosId, 'a' * 64);
      expect(body.method, ResolutionMethod.qr);
      expect(body.resolvedAtLogical.counter, 7);
      expect(body.nonce, sample().nonce);
    });

    test('a nonce of the wrong length is refused', () {
      // A short nonce is a smaller space to brute-force, and a long one is
      // somebody else's protocol.
      final body = _cborList([
        CborString('a' * 64),
        CborBytes(_bytes(ResolutionMessage.nonceLength - 1)),
        CborBytes(_bytes(ClaimSignature.publicKeyLength)),
        CborBytes(_bytes(ClaimSignature.signatureLength)),
        const CborSmallInt(0),
        _clock.toCbor(),
      ]);
      expect(ResolutionMessage.decode(body),
          isA<BodyDecodeError<ResolutionMessage>>());
    });

    test('autoExpired is refused — an SOS never expires (§2.3)', () {
      // The one enum value that must never reach a claim. `Claim`'s own
      // constructor asserts it too, but asserts are compiled out of release
      // builds and this is the wire.
      final decoded = ResolutionMessage.decode(
        sample(method: ResolutionMethod.autoExpired).encode(),
      );
      expect(decoded, isA<BodyDecodeError<ResolutionMessage>>());
    });

    test('the signing payload binds the id and the nonce together', () {
      // `sosId` alone travels the whole mesh in the clear, so a signature over
      // it proves nothing. The nonce is what ties the signature to one moment
      // of display.
      final a = ResolutionMessage.signingPayload('sos-1', [1, 2, 3]);
      final b = ResolutionMessage.signingPayload('sos-1', [1, 2, 4]);
      final c = ResolutionMessage.signingPayload('sos-2', [1, 2, 3]);
      expect(a, isNot(b));
      expect(a, isNot(c));
    });

    test('generated nonces are the right size and not repeated', () {
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        final n = ResolutionMessage.generateNonce();
        expect(n.length, ResolutionMessage.nonceLength);
        expect(seen.add(String.fromCharCodes(n)), isTrue,
            reason: 'a repeated nonce is a reusable rescue code');
      }
    });

    test('a signed message verifies, and does not after tampering', () async {
      final requester = await DeviceKeyPair.generate();
      final message = await ResolutionMessage.forDisplay(
        sosId: 'b' * 64,
        requesterKeyPair: requester,
        resolvedAtLogical: _clock,
      );

      expect(await message.verifyRequesterSignature(), isTrue);

      final tampered = ResolutionMessage(
        sosId: 'c' * 64,
        nonce: message.nonce,
        requesterPubKey: message.requesterPubKey,
        requesterSig: message.requesterSig,
        method: message.method,
        resolvedAtLogical: message.resolvedAtLogical,
      );
      expect(await tampered.verifyRequesterSignature(), isFalse);
    });

    for (final entry in _garbage.entries) {
      test('${entry.key} decodes to an error, never an exception', () {
        expect(ResolutionMessage.decode(entry.value),
            isA<BodyDecodeError<ResolutionMessage>>());
      });
    }
  });

  group('kind 3 — vouch', () {
    Uint8List body({int index = 1, int cap = VouchMessage.maxVouchCap}) {
      return _cborList([
        CborBytes(_bytes(ClaimSignature.publicKeyLength, 0x44)),
        CborSmallInt(index),
        CborSmallInt(cap),
        _clock.toCbor(),
      ]);
    }

    test('round-trips', () {
      final decoded = VouchMessage.decode(body(index: 2, cap: 5));

      expect(decoded, isA<BodyDecodeOk<VouchMessage>>());
      final v = (decoded as BodyDecodeOk<VouchMessage>).body;
      expect(v.vouchIndex, 2);
      expect(v.vouchCap, 5);
      expect(v.voucheePubKey.length, ClaimSignature.publicKeyLength);
    });

    test('a cap larger than this device honours is refused (§2.2)', () {
      // "Carried inside the signed vouch" only helps if the receiver also
      // refuses to believe an absurd one — a voucher signing `vouchCap: 500`
      // has signed something perfectly valid and entirely self-serving.
      expect(VouchMessage.decode(body(cap: VouchMessage.maxVouchCap + 1)),
          isA<BodyDecodeError<VouchMessage>>());
      expect(VouchMessage.decode(body(cap: 500)),
          isA<BodyDecodeError<VouchMessage>>());
    });

    test('an index past the vouch\'s own cap is refused', () {
      expect(VouchMessage.decode(body(index: 6, cap: 5)),
          isA<BodyDecodeError<VouchMessage>>());
    });

    test('a zero or negative index is refused', () {
      expect(VouchMessage.decode(body(index: 0)),
          isA<BodyDecodeError<VouchMessage>>());
    });

    test('the cap is 5, per MAYDAY_PROJECT_CONTEXT.md §2.2', () {
      // Pinned deliberately. Raising it is a §2.2 decision, not a tuning knob
      // — the cap is what bounds how fast one compromised phone can mint
      // volunteers.
      expect(VouchMessage.maxVouchCap, 5);
    });

    for (final entry in _garbage.entries) {
      test('${entry.key} decodes to an error, never an exception', () {
        expect(VouchMessage.decode(entry.value),
            isA<BodyDecodeError<VouchMessage>>());
      });
    }
  });

  group('kind 4 — revocation', () {
    test('round-trips every reason', () {
      for (final reason in RevocationReason.values) {
        final message = RevocationMessage(
          revokedPubKey: _bytes(ClaimSignature.publicKeyLength, 0x55),
          reason: reason,
          logicalClock: _clock,
        );
        final decoded = RevocationMessage.decode(message.encode());

        expect(decoded, isA<BodyDecodeOk<RevocationMessage>>());
        expect((decoded as BodyDecodeOk<RevocationMessage>).body.reason,
            reason);
      }
    });

    test('an unknown reason index is refused', () {
      final body = _cborList([
        CborBytes(_bytes(ClaimSignature.publicKeyLength)),
        CborSmallInt(RevocationReason.values.length),
        _clock.toCbor(),
      ]);
      expect(RevocationMessage.decode(body),
          isA<BodyDecodeError<RevocationMessage>>());
    });

    for (final entry in _garbage.entries) {
      test('${entry.key} decodes to an error, never an exception', () {
        expect(RevocationMessage.decode(entry.value),
            isA<BodyDecodeError<RevocationMessage>>());
      });
    }
  });

  group('kind 5 — volunteer beacon', () {
    test('round-trips', () {
      final decoded = BeaconMessage.decode(
        const BeaconMessage(beaconSeq: 12, logicalClock: _clock).encode(),
      );

      expect(decoded, isA<BodyDecodeOk<BeaconMessage>>());
      expect((decoded as BodyDecodeOk<BeaconMessage>).body.beaconSeq, 12);
    });

    test('hop distance is derived from the envelope, not the body', () {
      // There is deliberately no hop-count field in the body: the body is
      // exactly what `originSig` covers, so the first relay to increment one
      // would invalidate the signature and every device after it would drop
      // the beacon.
      expect(
        BeaconMessage.hopsTravelled(initialHopLimit: 5, envelopeHopLimit: 5),
        0,
      );
      expect(
        BeaconMessage.hopsTravelled(initialHopLimit: 5, envelopeHopLimit: 2),
        3,
      );
    });

    test('a forged hopLimit cannot produce a negative distance', () {
      // A stranger puts whatever hopLimit it likes on the wire. A negative
      // distance would sort that beacon to the front of the gradient, making
      // the least trustworthy packet the most preferred route.
      expect(
        BeaconMessage.hopsTravelled(initialHopLimit: 3, envelopeHopLimit: 99),
        0,
      );
    });

    test('a negative sequence is refused', () {
      final body = _cborList([const CborSmallInt(-1), _clock.toCbor()]);
      expect(BeaconMessage.decode(body), isA<BodyDecodeError<BeaconMessage>>());
    });

    for (final entry in _garbage.entries) {
      test('${entry.key} decodes to an error, never an exception', () {
        expect(BeaconMessage.decode(entry.value),
            isA<BodyDecodeError<BeaconMessage>>());
      });
    }
  });

  group('kind 6 — time gossip', () {
    test('round-trips a real epoch millisecond value', () {
      // ~1.7e12 does not fit CBOR's small-int encoding, unlike every other
      // integer on the wire. Encoding it as one would silently truncate.
      final now = DateTime.now().millisecondsSinceEpoch;
      final decoded = TimeGossipMessage.decode(
        TimeGossipMessage(wallClockMs: now, logicalClock: _clock).encode(),
      );

      expect(decoded, isA<BodyDecodeOk<TimeGossipMessage>>());
      expect((decoded as BodyDecodeOk<TimeGossipMessage>).body.wallClockMs,
          now);
    });

    test('a negative wall clock is refused', () {
      final body = _cborList([
        CborInt(BigInt.from(-1)),
        _clock.toCbor(),
      ]);
      expect(TimeGossipMessage.decode(body),
          isA<BodyDecodeError<TimeGossipMessage>>());
    });

    for (final entry in _garbage.entries) {
      test('${entry.key} decodes to an error, never an exception', () {
        expect(TimeGossipMessage.decode(entry.value),
            isA<BodyDecodeError<TimeGossipMessage>>());
      });
    }
  });
}
