// test/mesh/relay_queue_test.dart

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
import 'package:mayday/mesh/relay_queue.dart';

const _here = GeoPoint(lat: 12.9716, lon: 77.5946);

/// Records every (peer, envelope) pair the queue asked for, in order.
class _Radio {
  final List<({String peer, Envelope envelope})> sends = [];
  bool failEverything = false;

  Future<bool> send(RelayTarget target, Envelope envelope) async {
    if (failEverything) return false;
    sends.add((peer: target.peerId, envelope: envelope));
    return true;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DeviceKeyPair sender;
  late _Radio radio;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.instance.resetForTest();
    sender = await DeviceKeyPair.generate();
    radio = _Radio();
  });

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

  Future<Envelope> sos() => claimEnvelope(const SosPayload(location: _here));

  Future<Envelope> resource() => claimEnvelope(const ResourcePayload(
        location: _here,
        category: ResourceCategory.foodWater,
        pledgedCount: 5,
        claimedReports: 0,
      ));

  group('send ordering', () {
    test('volunteers are written to before other neighbours', () async {
      final queue = RelayQueue(sender: radio.send);
      queue.enqueue(await sos());

      await queue.drain(const [
        RelayTarget(peerId: 'bystander'),
        RelayTarget(peerId: 'volunteer', isVolunteer: true),
        RelayTarget(peerId: 'another-bystander'),
      ]);

      expect(radio.sends.first.peer, 'volunteer');
      expect(radio.sends.length, 3);
    });

    test('SOS is sent before a resource claim queued earlier', () async {
      final queue = RelayQueue(sender: radio.send);
      final rice = await resource();
      final help = await sos();

      // Resource first, so insertion order alone would send it first.
      queue.enqueue(rice);
      queue.enqueue(help);

      await queue.drain(const [RelayTarget(peerId: 'peer')]);

      expect(radio.sends.first.envelope.msgId, help.msgId);
      expect(radio.sends.last.envelope.msgId, rice.msgId);
    });
  });

  group('routing policy is honoured', () {
    test('a do-not-relay kind never enters the queue', () async {
      final queue = RelayQueue(sender: radio.send);
      final gossip = await EnvelopeSigner.sign(
        kind: EnvelopeKind.timeGossip,
        body: Uint8List.fromList([1]),
        keyPair: sender,
        hopLimit: 5,
      );

      expect(queue.enqueue(gossip), isFalse);
      expect(queue.length, 0);
    });
  });

  group('backpressure', () {
    test('resource traffic is shed once it is over cap', () async {
      final queue = RelayQueue(sender: radio.send, maxDroppable: 2);

      for (var i = 0; i < 5; i++) {
        queue.enqueue(await resource());
      }

      expect(queue.length, 2);
      expect(queue.droppedDroppable, 3);
    });

    test('the oldest resource claim is the one shed, not the newest',
        () async {
      final queue = RelayQueue(sender: radio.send, maxDroppable: 1);
      final stale = await resource();
      final fresh = await resource();

      queue.enqueue(stale);
      queue.enqueue(fresh);
      await queue.drain(const [RelayTarget(peerId: 'peer')]);

      // A superseded count is worth less than the one behind it.
      expect(radio.sends.single.envelope.msgId, fresh.msgId);
    });

    test('SOS is NEVER shed, however hard the queue is squeezed', () async {
      // CLAUDE.md §1.1. The caps are set to their most hostile values: there
      // is no configuration of this queue under which an SOS is discarded.
      final queue = RelayQueue(
        sender: radio.send,
        maxDroppable: 0,
        maxStandard: 0,
      );

      for (var i = 0; i < 50; i++) {
        expect(queue.enqueue(await sos()), isTrue);
      }

      expect(queue.length, 50);
      expect(queue.droppedDroppable, 0);
      expect(queue.droppedStandard, 0);
    });

    test('SOS survives while resource traffic around it is being shed',
        () async {
      final queue = RelayQueue(sender: radio.send, maxDroppable: 1);
      final help = await sos();

      queue.enqueue(help);
      for (var i = 0; i < 10; i++) {
        queue.enqueue(await resource());
      }

      await queue.drain(const [RelayTarget(peerId: 'peer')]);

      expect(
        radio.sends.map((s) => s.envelope.msgId).contains(help.msgId),
        isTrue,
      );
      expect(queue.droppedDroppable, 9);
    });
  });

  group('radio failure', () {
    test('a failed write is reported, not thrown', () async {
      final queue = RelayQueue(sender: radio.send);
      radio.failEverything = true;
      queue.enqueue(await sos());

      expect(await queue.drain(const [RelayTarget(peerId: 'peer')]), 0);
    });
  });
}
