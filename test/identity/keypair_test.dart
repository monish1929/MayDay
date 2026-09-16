// test/identity/keypair_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/signature.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DeviceKeyPair identity', () {
    test('generate() produces a 32-byte public key and 32-char deviceId',
        () async {
      final keyPair = await DeviceKeyPair.generate();

      expect(keyPair.publicKey.length, ClaimSignature.publicKeyLength);
      expect(keyPair.deviceId.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(keyPair.deviceId), isTrue);
    });

    test('two generated identities differ', () async {
      final a = await DeviceKeyPair.generate();
      final b = await DeviceKeyPair.generate();

      expect(a.deviceId, isNot(equals(b.deviceId)));
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });

    test('deviceId is derived from the public key, so it is reproducible',
        () async {
      final original = await DeviceKeyPair.generate();
      final seed = await original.persistableSeed();

      final rebuilt = await DeviceKeyPair.fromSeed(seed);

      expect(rebuilt.deviceId, original.deviceId);
      expect(rebuilt.publicKey, original.publicKey);
    });

    test('a rebuilt identity produces signatures the original key verifies',
        () async {
      final original = await DeviceKeyPair.generate();
      final rebuilt =
          await DeviceKeyPair.fromSeed(await original.persistableSeed());

      final message = [1, 2, 3, 4];
      final signature = await ClaimSignature.sign(message, rebuilt);

      expect(
        await ClaimSignature.verify(
          message,
          signature: signature,
          publicKey: original.publicKey,
        ),
        isTrue,
      );
    });

    test('seed round-trips at the expected length', () async {
      final keyPair = await DeviceKeyPair.generate();
      expect((await keyPair.persistableSeed()).length, DeviceKeyPair.seedLength);
    });
  });

  group('provisional persistence', () {
    test('identity survives across loads — the id must be stable', () async {
      final first = await DeviceKeyPair.loadOrCreateProvisional();
      final second = await DeviceKeyPair.loadOrCreateProvisional();

      expect(second.deviceId, first.deviceId);
      expect(second.publicKey, first.publicKey);
    });

    test('a wiped store yields a new identity — matches the uninstall story',
        () async {
      final before = await DeviceKeyPair.loadOrCreateProvisional();

      // Android deletes Keystore keys on uninstall (CLAUDE.md §9). Recovery
      // is via vouching, not key recovery — this asserts the identity really
      // is gone rather than silently reconstructable.
      SharedPreferences.setMockInitialValues({});

      final after = await DeviceKeyPair.loadOrCreateProvisional();
      expect(after.deviceId, isNot(equals(before.deviceId)));
    });
  });
}
