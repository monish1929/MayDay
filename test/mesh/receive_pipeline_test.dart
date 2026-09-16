// test/mesh/receive_pipeline_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/mesh/envelope.dart';
import 'package:mayday/mesh/envelope_signer.dart';
import 'package:mayday/mesh/receive_pipeline.dart';
import 'package:mayday/mesh/seen_message_cache.dart';

Uint8List _body(String s) => Uint8List.fromList(s.codeUnits);

/// Records what the pipeline handed onward, so tests can assert on calls that
/// should NOT have happened as directly as ones that should.
class _Spy {
  final List<Envelope> stored = [];
  final List<Envelope> relayed = [];

  Future<void> store(Envelope e) async => stored.add(e);
  Future<void> relay(Envelope e) async => relayed.add(e);
}

Envelope _copyWith(
  Envelope e, {
  int? hopLimit,
  Uint8List? body,
  Uint8List? originSig,
  Uint8List? msgId,
}) {
  return Envelope(
    v: e.v,
    msgId: msgId ?? e.msgId,
    hopLimit: hopLimit ?? e.hopLimit,
    kind: e.kind,
    body: body ?? e.body,
    originPubKey: e.originPubKey,
    originSig: originSig ?? e.originSig,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late _Spy spy;
  late SeenMessageCache cache;
  late ReceivePipeline pipeline;
  late DeviceKeyPair sender;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    spy = _Spy();
    cache = SeenMessageCache();
    pipeline = ReceivePipeline(
      seenCache: cache,
      store: spy.store,
      relay: spy.relay,
    );
    sender = await DeviceKeyPair.generate();
  });

  Future<Envelope> signed({int hopLimit = 5, String body = 'an SOS'}) {
    return EnvelopeSigner.sign(
      kind: EnvelopeKind.claim,
      body: _body(body),
      keyPair: sender,
      hopLimit: hopLimit,
    );
  }

  group('order and outcomes', () {
    test('a good envelope is stored and relayed once', () async {
      final envelope = await signed();

      expect(await pipeline.receive(envelope), ReceiveOutcome.storedAndRelayed);
      expect(spy.stored.length, 1);
      expect(spy.relayed.length, 1);
    });

    test('the same envelope twice, stored once and relayed once', () async {
      final envelope = await signed();

      expect(await pipeline.receive(envelope), ReceiveOutcome.storedAndRelayed);
      expect(await pipeline.receive(envelope), ReceiveOutcome.duplicate);

      expect(spy.stored.length, 1);
      expect(spy.relayed.length, 1);
    });

    test('a flood arriving via five neighbours is handled once', () async {
      // Every copy carries the same msgId, because relays preserve it.
      final original = await signed();

      for (var i = 0; i < 5; i++) {
        await pipeline.receive(
          _copyWith(original, hopLimit: original.hopLimit - i),
        );
      }

      expect(spy.stored.length, 1, reason: 'stored once, not five times');
      expect(spy.relayed.length, 1, reason: 'relayed once, no storm');
    });

    test('a tampered envelope is neither stored nor relayed', () async {
      final envelope = await signed();
      final tamperedBody = Uint8List.fromList(envelope.body);
      tamperedBody[0] ^= 0x01;

      final outcome =
          await pipeline.receive(_copyWith(envelope, body: tamperedBody));

      expect(outcome, ReceiveOutcome.signatureInvalid);
      expect(spy.stored, isEmpty);
      expect(spy.relayed, isEmpty);
    });

    test('an unsigned envelope is neither stored nor relayed', () async {
      final envelope = await signed();

      final outcome = await pipeline.receive(
        _copyWith(envelope, originSig: Uint8List(Envelope.signatureLength)),
      );

      expect(outcome, ReceiveOutcome.signatureInvalid);
      expect(spy.stored, isEmpty);
      expect(spy.relayed, isEmpty);
    });

    test('a rejected envelope is not recorded as seen', () async {
      // Otherwise flooding garbage msgIds would evict ids for real messages
      // still in flight, and the device would re-accept them.
      final envelope = await signed();

      await pipeline.receive(
        _copyWith(envelope, originSig: Uint8List(Envelope.signatureLength)),
      );
      expect(await cache.hasSeen(envelope.msgId), isFalse);

      // The genuine message with that same id still gets through afterwards.
      expect(await pipeline.receive(envelope), ReceiveOutcome.storedAndRelayed);
      expect(spy.stored.length, 1);
    });
  });

  group('hop limit', () {
    test('relay decrements hopLimit and preserves everything signed', () async {
      final envelope = await signed(hopLimit: 5);
      await pipeline.receive(envelope);

      final forwarded = spy.relayed.single;
      expect(forwarded.hopLimit, 4);
      expect(forwarded.msgId, envelope.msgId,
          reason: 'a fresh msgId would defeat de-dup downstream');
      expect(forwarded.body, envelope.body);
      expect(forwarded.originSig, envelope.originSig);
      expect(await EnvelopeSigner.verify(forwarded), isTrue,
          reason: 'the forwarded copy must still verify at the next hop');
    });

    test('hopLimit 1 leaves it stored with relay not attempted', () async {
      final envelope = await signed(hopLimit: 1);

      expect(await pipeline.receive(envelope),
          ReceiveOutcome.storedHopLimitReached);
      expect(spy.stored.length, 1);
      expect(spy.relayed, isEmpty);
    });

    test('hopLimit 0 is still stored, this device is a valid destination',
        () async {
      // Life-critical data is never silently discarded (CLAUDE.md 1.1). A hop
      // limit bounds travel, not whether the holder keeps it.
      final envelope = await signed(hopLimit: 0);

      expect(await pipeline.receive(envelope),
          ReceiveOutcome.storedHopLimitReached);
      expect(spy.stored.length, 1);
      expect(spy.relayed, isEmpty);
    });

    test('an envelope survives a realistic multi-hop chain', () async {
      var current = await signed(hopLimit: 3);
      final hops = <int>[];

      while (true) {
        // A fresh device at each hop: its own store and its own de-dup cache.
        final localSpy = _Spy();
        await DatabaseHelper.instance.resetForTest();
        final hopPipeline = ReceivePipeline(
          seenCache: SeenMessageCache(),
          store: localSpy.store,
          relay: localSpy.relay,
        );

        final outcome = await hopPipeline.receive(current);
        expect(localSpy.stored.length, 1,
            reason: 'every hop keeps its own copy');

        if (outcome == ReceiveOutcome.storedHopLimitReached) break;
        current = localSpy.relayed.single;
        hops.add(current.hopLimit);
      }

      expect(hops, [2, 1]);
    });
  });

  group('seen cache eviction', () {
    test('the table does not grow unbounded across a burst', () async {
      final smallCache = SeenMessageCache(maxEntries: 10);
      final burstPipeline = ReceivePipeline(
        seenCache: smallCache,
        store: spy.store,
        relay: spy.relay,
      );

      for (var i = 0; i < 50; i++) {
        await burstPipeline.receive(await signed(body: 'message $i'));
      }

      expect(await smallCache.count(), lessThanOrEqualTo(10));
      expect(spy.stored.length, 50, reason: 'all 50 were distinct messages');
    });

    test('the most recent ids survive eviction', () async {
      final smallCache = SeenMessageCache(maxEntries: 5);
      final burstPipeline = ReceivePipeline(
        seenCache: smallCache,
        store: spy.store,
        relay: spy.relay,
      );

      final envelopes = <Envelope>[];
      for (var i = 0; i < 20; i++) {
        final e = await signed(body: 'message $i');
        envelopes.add(e);
        await burstPipeline.receive(e);
      }

      // Newest still de-duped; oldest has aged out and would be re-accepted.
      expect(await smallCache.hasSeen(envelopes.last.msgId), isTrue);
      expect(await smallCache.hasSeen(envelopes.first.msgId), isFalse);
    });
  });
}
