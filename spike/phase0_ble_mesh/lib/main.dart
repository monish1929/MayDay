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

/// Arbitrary manufacturer id used to carry the node label ("A"/"B"/"C") in
/// the advertisement. 0xFFFF is the Bluetooth SIG's reserved "for internal
/// / test use" value, which is exactly what this is.
///
/// WHY NOT just use `Advertisement(name: ...)`: on Android that path calls
/// `BluetoothAdapter.setName()` — it renames the WHOLE PHONE's Bluetooth
/// name, system-wide and persistently — and then waits for an
/// ACTION_LOCAL_NAME_CHANGED broadcast to resolve its Future. If the
/// adapter name already equals the requested name, Android fires no
/// broadcast (nothing changed), the Future never completes, and
/// startAdvertising hangs forever with no error. That cost most of a day to
/// find; see PHASE0_MESH_FINDINGS.md §6. Manufacturer data stays inside the
/// advertising payload and touches no global state.
const int kNodeLabelManufacturerId = 0xFFFF;

/// Advertise payload budget is 31 bytes; flags (3) + one 128-bit service
/// UUID (18) already spends 21, and manufacturer data costs 4 bytes of
/// overhead on top of its content. Keep labels short — they are "A"/"B"/"C".
const int kMaxNodeLabelBytes = 6;

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

  /// Display name per peer, captured at discovery time — for the status
  /// chips below, so range testing shows "B" instead of a raw UUID.
  final Map<String, String> _peerNames = <String, String>{};

  /// Message ids already handled — the spike's stand-in for the de-dup cache.
  /// Without it, a three-phone flood echoes forever.
  final Set<String> _seenMsgIds = <String>{};

  // ---- liveness heartbeat (day 4 range test) ----
  //
  // Every write in this spike is connect -> write -> disconnect, one-shot —
  // there is no persistent connection to notice dropping, so nothing told
  // you "you just walked out of range" while it happened. This timer fixes
  // that: it pings every known peer every couple of seconds and tracks the
  // last time each one actually answered, so the UI can show live in-range
  // / out-of-range status instead of you re-tapping Send at every checkpoint.
  //
  // Deliberately NOT debounced — a single missed ping flips a peer to
  // "lost" immediately. That is what you want when you're trying to find
  // the exact spot range fails, not a smoothed-over average.
  Timer? _pingTimer;
  final Map<String, DateTime> _lastPingSuccess = <String, DateTime>{};
  final Map<String, bool> _peerReachable = <String, bool>{};

  /// Per-peer connection lock, checked by BOTH the ping heartbeat AND
  /// manual Send/Probe. This is load-bearing, not just anti-spam: the
  /// bluetooth_low_energy_android plugin is not safe against two
  /// concurrent connect() calls to the same peripheral — on real hardware
  /// this threw `IllegalStateException: GATT is disconnected with status:
  /// 0` deep in its connection-state handler when a manual Send raced a
  /// background ping to the same peer. Whichever gets here first wins;
  /// the other silently no-ops for that peer this cycle (manual Send just
  /// logs "busy", ping just skips — both retry naturally next tick/tap).
  final Set<String> _busyPeers = <String>{};

  /// The wire-level ping payload — deliberately NOT a `_SpikeMessage`. If it
  /// went through the normal parse path it would show up as an RX line (or
  /// a relay!) on the receiving phone, flooding their screen with noise
  /// every 2 seconds for a check they didn't ask for. `_onWriteRequest`
  /// special-cases this exact payload and answers it silently.
  static final Uint8List _pingPayload = Uint8List.fromList(utf8.encode('PING'));

  /// Set when discovery starts, so we can report time-to-first-discovery
  /// (Docs/PERSON_A.md §3, day 4 measurement).
  DateTime? _discoveryStartedAt;

  bool _advertising = false;
  bool _scanning = false;
  bool _advertiseBusy = false; // re-entrancy guard, see _toggleAdvertising
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
    _pingTimer?.cancel();
    for (final StreamSubscription<void> s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _say(String message) {
    // Also to the terminal — the on-screen list alone means whoever is
    // remote-debugging this (not physically holding the phone) has no way
    // to read RX/TX/FAILED lines except by transcription.
    debugPrint('[SPIKE] $message');
    if (!mounted) return;
    setState(() => _log.insert(0, LogLine(message)));
  }

  Future<void> _setUp() async {
    // Android 12+ BLE permissions. Expect this to be the fiddly part —
    // Docs/PERSON_A.md flags it; it is not a sign anything is broken.
    //
    // The three bluetoothX permissions are the real gate on every API
    // level. locationWhenInUse is checked separately and NOT treated as
    // fatal: the manifest declares ACCESS_FINE_LOCATION with
    // maxSdkVersion=30 (correct — API 31+ uses BLUETOOTH_SCAN's
    // neverForLocation flag instead). On API 31+ the OS has nothing to
    // grant for it, permission_handler reports "denied" by default, and
    // that used to trip a false "nothing will work" alarm on every modern
    // phone — see the PERSON_A.md log for how that read on a real device.
    final Map<Permission, PermissionStatus> btGranted = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    final PermissionStatus locationStatus =
        await Permission.locationWhenInUse.request();

    final Iterable<Permission> btDenied = btGranted.entries
        .where((MapEntry<Permission, PermissionStatus> e) => !e.value.isGranted)
        .map((MapEntry<Permission, PermissionStatus> e) => e.key);
    if (btDenied.isNotEmpty) {
      _say('PERMISSION DENIED: ${btDenied.join(', ')} — nothing will work');
    }
    if (!locationStatus.isGranted) {
      // Fine on API 31+ (see comment above). On API <=30 this IS required
      // for scan results and this line is your real warning.
      _say('location permission not granted — only matters below API 31');
    }

    await _central.authorize();
    await _peripheral.authorize();

    _subs.add(_central.discovered.listen(_onDiscovered));
    _subs.add(_peripheral.characteristicWriteRequested.listen(_onWriteRequest));

    // Runs for the app's whole lifetime; a no-op while _peers is empty.
    // 12s, not 4s: every connect() the plugin makes registers a BRAND NEW
    // GATT client identity rather than reusing one (confirmed by native
    // logs — dozens of distinct client UUIDs, one per attempt, never
    // reused). Android caps how many a process can hold concurrently; with
    // 3 phones each pinging up to 2 peers every few seconds, that cap got
    // hit for real — every registerApp() started failing with status=257
    // (registration table full), which looks identical to "peer
    // unreachable" but isn't a radio/range problem at all. This can't be
    // fixed from here (the plugin owns the registration strategy); the
    // only lever available is calling connect() less often. See
    // PHASE0_MESH_FINDINGS.md §8.
    _pingTimer = Timer.periodic(
        const Duration(seconds: 12), (_) => _pingAllPeers());

    _say('ready — set node name, then Advertise + Scan');
  }

  // --------------------------------------------------------------- peripheral

  Future<void> _toggleAdvertising() async {
    // Guard against stacking calls: on real hardware, startAdvertising()
    // hung forever (native advertiser handle wedged after an earlier BLE
    // crash — see PHASE0_MESH_FINDINGS.md). With no guard, every tap
    // re-entered this function and fired ANOTHER clearServices()+
    // addService() cycle on top of the still-hanging one, which is
    // confusing to debug and does nothing useful.
    if (_advertiseBusy) {
      _say('advertise toggle already in progress — wait for it to finish');
      return;
    }
    _advertiseBusy = true;

    // Every other BLE call in this file is try/caught. This one wasn't,
    // which meant a failure here (e.g. the Bluetooth adapter destabilized
    // by the connect() race documented on _busyPeers) failed SILENTLY —
    // the button looked "stuck" with no explanation on screen at all.
    try {
      if (_advertising) {
        await _peripheral.stopAdvertising().timeout(const Duration(seconds: 5));
        setState(() => _advertising = false);
        _say('advertising stopped');
        return;
      }

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

      await _peripheral.removeAllServices().timeout(const Duration(seconds: 5));
      await _peripheral.addService(
        GATTService(
          uuid: kServiceUuid,
          isPrimary: true,
          includedServices: <GATTService>[],
          characteristics: <GATTCharacteristic>[messageChar],
        ),
      ).timeout(const Duration(seconds: 5));
      // NOTE: deliberately no `name:` here — see kNodeLabelManufacturerId.
      // Passing a name renames the phone's global Bluetooth adapter and
      // hangs forever when it already matches. The label rides in
      // manufacturer data instead. Keep the timeout regardless: a native
      // BLE call that never returns must not be able to wedge the UI.
      final List<int> labelBytes = utf8
          .encode(_nodeName)
          .take(kMaxNodeLabelBytes)
          .toList();
      await _peripheral.startAdvertising(
        Advertisement(
          serviceUUIDs: <UUID>[kServiceUuid],
          manufacturerSpecificData: <ManufacturerSpecificData>[
            ManufacturerSpecificData(
              id: kNodeLabelManufacturerId,
              data: Uint8List.fromList(labelBytes),
            ),
          ],
        ),
      ).timeout(const Duration(seconds: 5));

      setState(() => _advertising = true);
      _say('advertising as "$_nodeName"');
    } on TimeoutException {
      _say('ADVERTISE FAILED: timed out — Bluetooth adapter is likely '
          'wedged at the OS level. Try airplane mode on/off, or reboot '
          'the phone. See PHASE0_MESH_FINDINGS.md.');
    } catch (e) {
      _say('ADVERTISE FAILED: $e');
    } finally {
      _advertiseBusy = false;
    }
  }

  /// A message arrived over the air. This is the whole point of the spike.
  void _onWriteRequest(GATTCharacteristicWriteRequestedEventArgs args) {
    // Heartbeat ping — answer and stop. See _pingPayload's doc comment for
    // why this must never reach the normal parse/log/relay path below.
    if (args.request.value.length == _pingPayload.length &&
        utf8.decode(args.request.value, allowMalformed: true) == 'PING') {
      _peripheral.respondWriteRequest(args.request);
      return;
    }

    final String raw = utf8.decode(args.request.value, allowMalformed: true);
    _peripheral.respondWriteRequest(args.request);

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

  Future<void> _toggleScanning() async {
    try {
      if (_scanning) {
        await _central.stopDiscovery();
        setState(() => _scanning = false);
        _say('scanning stopped');
        return;
      }

      // Clear previously-found peers on restart, not just on first start —
      // the Day 4 best/worst-of-10 discovery timing (Docs/PERSON_A.md §3)
      // needs a fresh FOUND for every run, and _onDiscovered ignores
      // anything already in _peers. Also clear every heartbeat-tracking
      // map keyed off the same peer UUID — otherwise a fresh FOUND after a
      // restart still shows a stale status chip (old timestamp, old
      // red/green) from before the restart, which reads as a bug even
      // though discovery itself worked.
      setState(() {
        _peers.clear();
        _peerNames.clear();
        _lastPingSuccess.clear();
        _peerReachable.clear();
        _busyPeers.clear();
      });
      _discoveryStartedAt = DateTime.now();
      await _central.startDiscovery(serviceUUIDs: <UUID>[kServiceUuid]);
      setState(() => _scanning = true);
      _say('scanning...');
    } catch (e) {
      _say('SCAN FAILED: $e');
    }
  }

  /// Node label, read from manufacturer data rather than the advertised
  /// device name — see kNodeLabelManufacturerId for why we never set a name.
  /// Falls back to the peripheral uuid so an unlabelled peer still shows up.
  String _labelOf(DiscoveredEventArgs args, String fallback) {
    for (final ManufacturerSpecificData d
        in args.advertisement.manufacturerSpecificData) {
      if (d.id == kNodeLabelManufacturerId && d.data.isNotEmpty) {
        return utf8.decode(d.data, allowMalformed: true);
      }
    }
    return fallback;
  }

  void _onDiscovered(DiscoveredEventArgs args) {
    final String key = args.peripheral.uuid.toString();
    if (_peers.containsKey(key)) return;

    final Duration? elapsed = _discoveryStartedAt == null
        ? null
        : DateTime.now().difference(_discoveryStartedAt!);
    final String label = _labelOf(args, key);
    setState(() {
      _peers[key] = args.peripheral;
      _peerNames[key] = label;
    });
    _say('FOUND $label  rssi=${args.rssi}'
        '${elapsed == null ? '' : '  after ${elapsed.inMilliseconds}ms'}');
  }

  /// Heartbeat sweep — one ping per known peer, every 4s. Updates
  /// _lastPingSuccess / _peerReachable for the status chips; logs only on a
  /// reachable<->unreachable *transition*, not every tick, or the log would
  /// be 100% ping noise within a minute.
  Future<void> _pingAllPeers() async {
    for (final MapEntry<String, Peripheral> entry in _peers.entries.toList()) {
      final String key = entry.key;
      if (_busyPeers.contains(key)) continue; // previous ping still in flight
      _busyPeers.add(key);
      try {
        // Timeout is load-bearing, not decoration: without it, a connect()
        // that hangs on real hardware (radio contention did this once —
        // see PHASE0_MESH_FINDINGS.md) never throws, `_busyPeers` never
        // clears, and this peer's status chip freezes forever, silently
        // skipped by every future sweep. 3s < the 4s sweep interval, so a
        // timed-out peer is eligible again next cycle instead of stacking.
        await _pingOnce(entry.value).timeout(const Duration(seconds: 3));
        _lastPingSuccess[key] = DateTime.now();
        if (_peerReachable[key] != true) {
          debugPrint('[SPIKE] ${_peerNames[key]} back in range');
          _peerReachable[key] = true;
        }
      } catch (e) {
        if (_peerReachable[key] != false) {
          // The real error, not swallowed — the first "lost" on real
          // hardware turned out to be BLE stack contention (continuous
          // Scan + rapid connect/disconnect churn), not actual range loss.
          // Without this line that took reading raw adb logcat to diagnose.
          debugPrint('[SPIKE] ${_peerNames[key]} lost: $e');
          _peerReachable[key] = false;
        }
      } finally {
        // Best-effort — if connect() itself is what's hanging, disconnect()
        // might hang too. Never let cleanup itself be the next freeze.
        try {
          await _central.disconnect(entry.value).timeout(
              const Duration(seconds: 2));
        } catch (_) {}
        _busyPeers.remove(key);
      }
    }
    if (mounted) setState(() {}); // refresh "Ns ago" even with no state change
  }

  /// One connect -> discover -> write attempt against a single peer.
  /// Extracted from _pingAllPeers purely so the whole chain can be wrapped
  /// in one `.timeout(...)` call there.
  Future<void> _pingOnce(Peripheral peer) async {
    await _central.connect(peer);
    final List<GATTService> services = await _central.discoverGATT(peer);
    final GATTCharacteristic target = services
        .firstWhere((GATTService s) => s.uuid == kServiceUuid)
        .characteristics
        .firstWhere((GATTCharacteristic c) => c.uuid == kMessageCharUuid);
    await _central.writeCharacteristic(
      peer,
      target,
      value: _pingPayload,
      type: GATTCharacteristicWriteType.withResponse,
    );
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
    for (final MapEntry<String, Peripheral> entry in _peers.entries.toList()) {
      final String key = entry.key;
      final Peripheral peer = entry.value;
      if (_busyPeers.contains(key)) {
        // The ping heartbeat is mid-connection to this exact peer right
        // now. Don't race it — see _busyPeers' doc comment for why that
        // crashed the plugin on real hardware. Just skip; tap again.
        _say('     -> $label SKIPPED ${peer.uuid} (ping in flight, retry)');
        continue;
      }
      _busyPeers.add(key);
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
        try {
          await _central.disconnect(peer).timeout(const Duration(seconds: 2));
        } catch (_) {}
        _busyPeers.remove(key);
      }
    }
  }

  // -------------------------------------------------------------------- ui

  /// Live in-range/out-of-range chip for one peer. This is the thing to
  /// watch while walking outdoors for the Day 4 range test — green means
  /// the last heartbeat (within the last 2s cycle) succeeded, red means it
  /// didn't. "Ns ago" keeps ticking even while red, so you can tell "just
  /// lost it" from "lost it a while back and it's not coming back."
  Widget _buildPeerStatusChip(String key) {
    final String name = _peerNames[key] ?? key;
    final DateTime? lastSuccess = _lastPingSuccess[key];
    final bool reachable = _peerReachable[key] ?? false;
    final String agoText = lastSuccess == null
        ? 'no contact yet'
        : '${DateTime.now().difference(lastSuccess).inSeconds}s ago';

    return Chip(
      avatar: Icon(
        reachable ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
        color: Colors.white,
        size: 18,
      ),
      label: Text('$name — $agoText'),
      backgroundColor: reachable ? Colors.green[700] : Colors.red[700],
      labelStyle: const TextStyle(color: Colors.white),
    );
  }

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
                onPressed: _toggleAdvertising,
                child: Text(_advertising ? 'Stop advertising' : 'Advertise'),
              ),
              FilledButton(
                onPressed: _toggleScanning,
                child: Text(_scanning ? 'Stop scanning' : 'Scan'),
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
          if (_peers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _peers.keys.map(_buildPeerStatusChip).toList(),
              ),
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
