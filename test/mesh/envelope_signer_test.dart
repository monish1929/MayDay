// test/mesh/envelope_signer_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/mesh/envelope_signer.dart';

Uint8List _body(String s) => Uint8List.fromList(s.codeUnits);

Envelope _copyWith(
  Envelope e, {
  int? v,
  Uint8List? msgId,
  int? hopLimit,
  EnvelopeKind? kind,
  Uint8List? body,
  Uint8List? originPubKey,
  Uint8List? originSig,
}) {
  return Envelope(
    v: v ?? e.v,
    msgId: msgId ?? e.msgId,
    hopLimit: hopLimit ?? e.hopLimit,
    kind: kind ?? e.kind,
    body: body ?? e.body,
    originPubKey: originPubKey ?? e.originPubKey,
    originSig: originSig ?? e.originSig,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('sign / verify at the hop (§9.3 step 2)', () {
    test('a freshly signed envelope verifies', () async {
      final keyPair = await DeviceKeyPair.generate();
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS'),
        keyPair: keyPair,
        hopLimit: 5,
      );

      expect(await EnvelopeSigner.verify(envelope), isTrue);
      expect(envelope.originPubKey, keyPair.publicKey);
      expect(envelope.originSig.length, Envelope.signatureLength);
    });

    test('it still verifies after a full encode/decode round-trip', () async {
      final keyPair = await DeviceKeyPair.generate();
      final signed = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS'),
        keyPair: keyPair,
        hopLimit: 5,
      );

      final result = Envelope.decode(signed.encode());
      expect(result, isA<EnvelopeDecodeOk>());

      expect(
        await EnvelopeSigner.verify((result as EnvelopeDecodeOk).envelope),
        isTrue,
      );
    });

    test('a body byte flipped after signing fails verification', () async {
      final keyPair = await DeviceKeyPair.generate();
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('resource: 50 packets'),
        keyPair: keyPair,
        hopLimit: 5,
      );

      final tamperedBody = Uint8List.fromList(envelope.body);
      tamperedBody[0] ^= 0x01;

      expect(
        await EnvelopeSigner.verify(_copyWith(envelope, body: tamperedBody)),
        isFalse,
      );
    });

    test('a zeroed signature is rejected, not treated as unsigned-but-ok',
        () async {
      final keyPair = await DeviceKeyPair.generate();
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS'),
        keyPair: keyPair,
        hopLimit: 5,
      );

      expect(
        await EnvelopeSigner.verify(_copyWith(
          envelope,
          originSig: Uint8List(Envelope.signatureLength),
        )),
        isFalse,
      );
      // Absent entirely, not merely wrong.
      expect(
        await EnvelopeSigner.verify(_copyWith(
          envelope,
          originSig: Uint8List(0),
        )),
        isFalse,
      );
    });

    test('swapping in another device key fails verification', () async {
      final mine = await DeviceKeyPair.generate();
      final theirs = await DeviceKeyPair.generate();
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS'),
        keyPair: mine,
        hopLimit: 5,
      );

      expect(
        await EnvelopeSigner.verify(
          _copyWith(envelope, originPubKey: theirs.publicKey),
        ),
        isFalse,
      );
    });

    test('changing kind or v after signing fails verification', () async {
      final keyPair = await DeviceKeyPair.generate();
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS'),
        keyPair: keyPair,
        hopLimit: 5,
      );

      expect(
        await EnvelopeSigner.verify(
          _copyWith(envelope, kind: EnvelopeKind.corroboration),
        ),
        isFalse,
      );
      expect(
        await EnvelopeSigner.verify(_copyWith(envelope, v: 2)),
        isFalse,
      );
    });
  });

  group('the signature scope exclusion is real, not just documented', () {
    test('a relay hop mutating hopLimit and msgId still verifies', () async {
      final keyPair = await DeviceKeyPair.generate();
      final original = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS that must survive three hops'),
        keyPair: keyPair,
        hopLimit: 5,
      );

      // Exactly what a relay does: decrement hopLimit, new msgId for the
      // onward transmission. Everything the signature covers is untouched.
      var relayed = original;
      for (var hop = 0; hop < 3; hop++) {
        relayed = _copyWith(
          relayed,
          hopLimit: relayed.hopLimit - 1,
          msgId: Envelope.generateMsgId(),
        );
        expect(
          await EnvelopeSigner.verify(relayed),
          isTrue,
          reason: 'must still verify after hop ${hop + 1}',
        );
      }

      expect(relayed.hopLimit, 2);
      expect(relayed.msgId, isNot(equals(original.msgId)));
    });
  });

  group('device id binding', () {
    test('the id derived from the envelope key matches the signer', () async {
      final keyPair = await DeviceKeyPair.generate();
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS'),
        keyPair: keyPair,
        hopLimit: 5,
      );

      expect(
        EnvelopeSigner.matchesDeviceId(envelope, keyPair.deviceId),
        isTrue,
      );
    });

    test('a claim naming a different device id is caught', () async {
      final attacker = await DeviceKeyPair.generate();
      final victim = await DeviceKeyPair.generate();

      // Signed correctly by the attacker, but claiming to be the victim.
      // Signature verification alone passes here -- only the id binding
      // catches it.
      final envelope = await EnvelopeSigner.sign(
        kind: EnvelopeKind.claim,
        body: _body('an SOS'),
        keyPair: attacker,
        hopLimit: 5,
      );

      expect(await EnvelopeSigner.verify(envelope), isTrue);
      expect(
        EnvelopeSigner.matchesDeviceId(envelope, victim.deviceId),
        isFalse,
      );
    });
  });
}
