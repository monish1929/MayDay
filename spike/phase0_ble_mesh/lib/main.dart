// Phase 0 BLE mesh spike — THROWAWAY CODE.
//
// This is NOT the MayDay app and none of it survives into lib/mesh/.
// The deliverable of this file is knowledge, not code: see
// Docs/PERSON_A.md §3 for the four questions it exists to answer.
//
// Deliberately NOT done here (all Phase 2, per CLAIM_SCHEMA.md §9):
//   - CBOR envelopes             - Ed25519 signature verification
//   - the real receive pipeline  - persistence of any kind
// The wire payload below is a plain string on purpose. Do not "improve" it
// into the real envelope — a spike that drifts toward the real thing stops
// answering the hardware question and starts hiding it.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Custom service every spike node advertises and scans for.
/// Random UUID — no meaning, it just has to be identical on all three phones.
final UUID kServiceUuid =
    UUID.fromString('7a9f1c40-5d3e-4b18-9a62-0c1e5f8d2b77');

/// The one writable characteristic. A "message" is a single write to this.
final UUID kMessageCharUuid =
    UUID.fromString('7a9f1c41-5d3e-4b18-9a62-0c1e5f8d2b77');

/// Spike-only hop cap. This is NOT the real `hopLimit` default — that number
/// is TBD and blocked on the range data this very spike produces
/// (Docs/PERSON_A.md §9). Three is just "enough to prove A->B->C works".
const int kSpikeHopLimit = 3;

void main() => runApp(const SpikeApp());

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MayDay Phase 0 spike',
        theme: ThemeData(colorSchemeSeed: Colors.deepOrange),
        home: const SpikeHome(),
      );
}

/// One line in the on-screen log.
class LogLine {
  LogLine(this.text) : at = DateTime.now();
  final String text;
  final DateTime at;
}

class SpikeHome extends StatefulWidget {
  const SpikeHome({super.key});

  @override
  State<SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<SpikeHome> {
  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();

  final List<LogLine> _log = <LogLine>[];
  final List<StreamSubscription<void>> _subs = <StreamSubscription<void>>[];

  /// Peers seen advertising our service UUID, keyed by peripheral uuid.
  final Map<String, Peripheral> _peers = <String, Peripheral>{};

  /// Message ids already handled — the spike's stand-in for the de-dup cache.
  /// Without it, a three-phone flood echoes forever.
  final Set<String> _seenMsgIds = <String>{};

  /// Set when discovery starts, so we can report time-to-first-discovery
  /// (Docs/PERSON_A.md §3, day 4 measurement).
  DateTime? _discoveryStartedAt;

  bool _advertising = false;
  bool _scanning = false;
  bool _relayEnabled = true;
  int _sendCounter = 0;

  /// Short label so the three phones are distinguishable in the log.
  /// Set it per-device from the UI before testing.
  String _nodeName = 'NODE';

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  @override
  void dispose() {
    for (final StreamSubscription<void> s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _say(String message) {
    if (!mounted) return;
    setState(() => _log.insert(0, LogLine(message)));
  }

  Future<void> _setUp() async {
    // Android 12+ BLE permissions. Expect this to be the fiddly part —
    // Docs/PERSON_A.md flags it; it is not a sign anything is broken.
    final Map<Permission, PermissionStatus> granted = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // required below API 31
    ].request();
    final Iterable<Permission> denied = granted.entries
        .where((MapEntry<Permission, PermissionStatus> e) => !e.value.isGranted)
        .map((MapEntry<Permission, PermissionStatus> e) => e.key);
    if (denied.isNotEmpty) {
      _say('PERMISSION DENIED: ${denied.join(', ')} — nothing will work');
    }

    await _central.authorize();
    await _peripheral.authorize();

    _subs.add(_central.discovered.listen(_onDiscovered));
    _subs.add(_peripheral.characteristicWriteRequested.listen(_onWriteRequest));

    _say('ready — set node name, then Advertise + Scan');
  }

  // --------------------------------------------------------------- peripheral

  Future<void> _startAdvertising() async {
    final GATTCharacteristic messageChar = GATTCharacteristic.mutable(
      uuid: kMessageCharUuid,
      properties: <GATTCharacteristicProperty>[
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: <GATTCharacteristicPermission>[
        GATTCharacteristicPermission.write,
      ],
      descriptors: <GATTDescriptor>[],
    );

    await _peripheral.removeAllServices();
    await _peripheral.addService(
      GATTService(
        uuid: kServiceUuid,
        isPrimary: true,
        includedServices: <GATTService>[],
        characteristics: <GATTCharacteristic>[messageChar],
      ),
    );
    await _peripheral.startAdvertising(
      Advertisement(
        name: _nodeName,
        serviceUUIDs: <UUID>[kServiceUuid],
      ),
    );

    setState(() => _advertising = true);
    _say('advertising as "$_nodeName"');
  }

  /// A message arrived over the air. This is the whole point of the spike.
  void _onWriteRequest(GATTCharacteristicWriteRequestedEventArgs args) {
    final String raw = utf8.decode(args.request.value, allowMalformed: true);
    _peripheral.respondWriteRequest(args.central, args.request);

    final _SpikeMessage? msg = _SpikeMessage.tryParse(raw);
    if (msg == null) {
      _say('RX malformed: $raw');
      return;
    }
    if (_seenMsgIds.contains(msg.id)) {
      _say('RX dup ${msg.id} — dropped, not relayed');
      return;
    }
    _seenMsgIds.add(msg.id);
    _say('RX  "${msg.text}"  from ${msg.origin}  hops=${msg.hops}');

    if (!_relayEnabled) {
      _say('     relay OFF — stopping here');
      return;
    }
    if (msg.hops + 1 >= kSpikeHopLimit) {
      _say('     hop limit reached — stopping here');
      return;
    }
    // The A->B->C test: B must forward, and delivery to C must STOP once B
    // is removed. That is the only way to prove C is not hearing A directly.
    _broadcast(msg.forwarded());
  }

  // ------------------------------------------------------------------ central

  Future<void> _startScanning() async {
    _discoveryStartedAt = DateTime.now();
    await _central.startDiscovery(serviceUUIDs: <UUID>[kServiceUuid]);
    setState(() => _scanning = true);
    _say('scanning...');
  }

  void _onDiscovered(DiscoveredEventArgs args) {
    final String key = args.peripheral.uuid.toString();
    if (_peers.containsKey(key)) return;

    final Duration? elapsed = _discoveryStartedAt == null
        ? null
        : DateTime.now().difference(_discoveryStartedAt!);
    setState(() => _peers[key] = args.peripheral);
    _say('FOUND ${args.advertisement.name ?? key}  rssi=${args.rssi}'
        '${elapsed == null ? '' : '  after ${elapsed.inMilliseconds}ms'}');
  }

  Future<void> _send() async {
    final _SpikeMessage msg = _SpikeMessage(
      id: '$_nodeName-${_sendCounter++}',
      origin: _nodeName,
      hops: 0,
      text: 'hello from $_nodeName',
    );
    _seenMsgIds.add(msg.id); // never relay our own message back out
    _say('TX  "${msg.text}"  to ${_peers.length} peer(s)');
    await _broadcast(msg);
  }

  /// Write to every known peer. Full flood, no neighbour selection —
  /// selective relay is a Phase 4 concern, not a Phase 0 one.
  Future<void> _broadcast(_SpikeMessage msg) async {
    final Uint8List body = Uint8List.fromList(utf8.encode(msg.encode()));
    await _writeToAllPeers(body, label: '${body.length}B');
  }

  /// Day 4: find the largest payload that reliably lands in ONE write.
  /// CLAIM_SCHEMA.md §9.2 assumes 400 bytes fits. If it does not, that is a
  /// three-person conversation, not a quiet fragmentation feature.
  Future<void> _probePayloadSize(int bytes) async {
    final Uint8List body = Uint8List.fromList(List<int>.filled(bytes, 0x41));
    await _writeToAllPeers(body, label: 'probe ${bytes}B', requestMtu: true);
  }

  Future<void> _writeToAllPeers(
    Uint8List body, {
    required String label,
    bool requestMtu = false,
  }) async {
    for (final Peripheral peer in _peers.values.toList()) {
      try {
        await _central.connect(peer);
        if (requestMtu) {
          final int mtu = await _central.requestMTU(peer, mtu: 517);
          _say('     negotiated mtu=$mtu with ${peer.uuid}');
        }
        final List<GATTService> services = await _central.discoverGATT(peer);
        final GATTCharacteristic target = services
            .firstWhere((GATTService s) => s.uuid == kServiceUuid)
            .characteristics
            .firstWhere((GATTCharacteristic c) => c.uuid == kMessageCharUuid);

        await _central.writeCharacteristic(
          peer,
          target,
          value: body,
          type: GATTCharacteristicWriteType.withResponse,
        );
        _say('     -> $label OK to ${peer.uuid}');
      } catch (e) {
        _say('     -> $label FAILED to ${peer.uuid}: $e');
      } finally {
        await _central.disconnect(peer);
      }
    }
  }

  // -------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Phase 0 spike — $_nodeName')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Node name (set A, B or C before testing)',
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) => setState(
                  () => _nodeName = v.trim().isEmpty ? 'NODE' : v.trim()),
            ),
          ),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: _advertising ? null : _startAdvertising,
                child: const Text('Advertise'),
              ),
              FilledButton(
                onPressed: _scanning ? null : _startScanning,
                child: const Text('Scan'),
              ),
              FilledButton(
                onPressed: _peers.isEmpty ? null : _send,
                child: Text('Send (${_peers.length})'),
              ),
              OutlinedButton(
                onPressed: _peers.isEmpty ? null : () => _probePayloadSize(400),
                child: const Text('Probe 400B'),
              ),
              OutlinedButton(
                onPressed: _peers.isEmpty ? null : () => _probePayloadSize(512),
                child: const Text('Probe 512B'),
              ),
            ],
          ),
          SwitchListTile(
            title: const Text('Relay received messages'),
            subtitle: const Text('Turn OFF on the middle phone to prove '
                'A and C cannot reach each other directly'),
            value: _relayEnabled,
            onChanged: (bool v) => setState(() => _relayEnabled = v),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (BuildContext context, int i) {
                final LogLine line = _log[i];
                return ListTile(
                  dense: true,
                  title: Text(line.text,
                      style: const TextStyle(fontFamily: 'monospace')),
                  trailing: Text(
                    '${line.at.minute.toString().padLeft(2, '0')}:'
                    '${line.at.second.toString().padLeft(2, '0')}.'
                    '${line.at.millisecond.toString().padLeft(3, '0')}',
                    style: const TextStyle(fontSize: 11),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Spike wire format: `id|origin|hops|text`. Plain text on purpose — the real
/// format is CBOR + Ed25519 (CLAIM_SCHEMA.md §9) and belongs to Phase 2.
class _SpikeMessage {
  _SpikeMessage({
    required this.id,
    required this.origin,
    required this.hops,
    required this.text,
  });

  final String id;
  final String origin;
  final int hops;
  final String text;

  static _SpikeMessage? tryParse(String raw) {
    final List<String> parts = raw.split('|');
    if (parts.length < 4) return null;
    final int? hops = int.tryParse(parts[2]);
    if (hops == null) return null;
    return _SpikeMessage(
      id: parts[0],
      origin: parts[1],
      hops: hops,
      text: parts.sublist(3).join('|'),
    );
  }

  String encode() => '$id|$origin|$hops|$text';

  _SpikeMessage forwarded() => _SpikeMessage(
        id: id,
        origin: origin,
        hops: hops + 1,
        text: text,
      );
}
