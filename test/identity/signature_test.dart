// test/identity/signature_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/signature.dart';

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('sign / verify round-trip (§5)', () {
    test('a signature from a keypair verifies against its own public key',
        () async {
      final keyPair = await DeviceKeyPair.generate();
      final message = _bytes('an SOS from someone who needs help');

      final signature = await ClaimSignature.sign(message, keyPair);

      expect(signature.length, ClaimSignature.signatureLength);
      expect(
        await ClaimSignature.verify(
          message,
          signature: signature,
          publicKey: keyPair.publicKey,
        ),
        isTrue,
      );
    });

    test('a tampered message fails verification', () async {
      final keyPair = await DeviceKeyPair.generate();
      final message = _bytes('resource: 50 water packets');
      final signature = await ClaimSignature.sign(message, keyPair);

      final tampered = _bytes('resource: 99 water packets');

      expect(
        await ClaimSignature.verify(
          tampered,
          signature: signature,
          publicKey: keyPair.publicKey,
        ),
        isFalse,
      );
    });

    test('a single flipped bit in the signature fails verification', () async {
      final keyPair = await DeviceKeyPair.generate();
      final message = _bytes('hazard: bridge out');
      final signature = await ClaimSignature.sign(message, keyPair);

      final flipped = Uint8List.fromList(signature);
      flipped[0] ^= 0x01;

      expect(
        await ClaimSignature.verify(
          message,
          signature: flipped,
          publicKey: keyPair.publicKey,
        ),
        isFalse,
      );
    });

    test("another device's key does not verify this device's signature",
        () async {
      final mine = await DeviceKeyPair.generate();
      final theirs = await DeviceKeyPair.generate();
      final message = _bytes('claim body');

      final signature = await ClaimSignature.sign(message, mine);

      expect(
        await ClaimSignature.verify(
          message,
          signature: signature,
          publicKey: theirs.publicKey,
        ),
        isFalse,
      );
    });
  });

  group('malformed input is rejected, never thrown on (§9.3)', () {
    // The sender is a stranger's phone. Malformed input is an expected
    // message, not a bug — a verifier that threw would crash the receive path.
    test('an all-zero signature is rejected, not treated as unsigned-but-ok',
        () async {
      final keyPair = await DeviceKeyPair.generate();
      final message = _bytes('claim body');

      expect(
        await ClaimSignature.verify(
          message,
          signature: Uint8List(ClaimSignature.signatureLength),
          publicKey: keyPair.publicKey,
        ),
        isFalse,
      );
    });

    test('an empty signature returns false', () async {
      final keyPair = await DeviceKeyPair.generate();
      expect(
        await ClaimSignature.verify(
          _bytes('body'),
          signature: Uint8List(0),
          publicKey: keyPair.publicKey,
        ),
        isFalse,
      );
    });

    test('a truncated signature returns false', () async {
      final keyPair = await DeviceKeyPair.generate();
      final signature = await ClaimSignature.sign(_bytes('body'), keyPair);

      expect(
        await ClaimSignature.verify(
          _bytes('body'),
          signature: signature.sublist(0, 32),
          publicKey: keyPair.publicKey,
        ),
        isFalse,
      );
    });

    test('an empty or wrong-length public key returns false', () async {
      final keyPair = await DeviceKeyPair.generate();
      final signature = await ClaimSignature.sign(_bytes('body'), keyPair);

      expect(
        await ClaimSignature.verify(
          _bytes('body'),
          signature: signature,
          publicKey: Uint8List(0),
        ),
        isFalse,
      );
      expect(
        await ClaimSignature.verify(
          _bytes('body'),
          signature: signature,
          publicKey: Uint8List(16),
        ),
        isFalse,
      );
    });

    test('garbage bytes in both fields return false', () async {
      expect(
        await ClaimSignature.verify(
          _bytes('body'),
          signature: Uint8List.fromList(List<int>.filled(64, 0xFF)),
          publicKey: Uint8List.fromList(List<int>.filled(32, 0xFF)),
        ),
        isFalse,
      );
    });

    test('an empty message still signs and verifies', () async {
      final keyPair = await DeviceKeyPair.generate();
      final signature = await ClaimSignature.sign(Uint8List(0), keyPair);

      expect(
        await ClaimSignature.verify(
          Uint8List(0),
          signature: signature,
          publicKey: keyPair.publicKey,
        ),
        isTrue,
      );
    });
  });
}
