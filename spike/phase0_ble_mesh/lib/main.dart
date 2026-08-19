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
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
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

  // ---- liveness, from advertisements (day 4 range test) ----
  //
  // REPLACED an earlier connect->write->disconnect "ping" heartbeat. That
  // design was wrong twice over:
  //   1. It caused the GATT client registration exhaustion in
  //      PHASE0_MESH_FINDINGS.md §8 — every connect() registers a fresh
  //      client, Android caps them per process, and 3 phones pinging each
  //      other burned through the cap. Widening the interval only delayed it.
  //   2. It measured the wrong thing anyway. A peer is "in range" for mesh
  //      purposes when you can HEAR IT — advertisement reception is what
  //      decides whether a mesh forms at all.
  //
  // BLE peripherals advertise continuously (hundreds of ms apart), so as
  // long as we are scanning, liveness arrives free: just record when each
  // peer was last heard. No connections, no registrations, no radio churn,
  // far less battery (which also stops us polluting the Day 4 battery
  // numbers with our own instrumentation), and RSSI updates live as you walk.
  //
  // Caveat worth stating: this means "in range" == "I can hear its
  // advertisements", NOT "I can complete a GATT write to it". Those differ
  // at the margins — write range is usually shorter. Send / Probe are how
  // you test writes; the chips are how you find the discovery boundary.
  final Map<String, DateTime> _lastSeenAt = <String, DateTime>{};
  final Map<String, int> _lastRssi = <String, int>{};

  /// A peer is shown as lost after this long with no advertisement. Advert
  /// intervals are sub-second, so 4s is many missed adverts — long enough
  /// not to flicker on a single dropped packet, short enough to pinpoint
  /// where range actually ends while walking.
  static const Duration kPeerStaleAfter = Duration(seconds: 4);

  /// Repaints the "Ns ago" text between advertisements. UI only — liveness
  /// itself comes from _lastSeenAt, not from this timer firing.
  Timer? _uiTicker;

  /// Per-peer connection lock for manual Send/Probe. Load-bearing, not just
  /// anti-spam: the bluetooth_low_energy_android plugin is not safe against
  /// two concurrent connect() calls to the same peripheral — on real
  /// hardware that threw `IllegalStateException: GATT is disconnected with
  /// status: 0` deep in its connection-state handler when two writes raced
  /// to the same peer.
  final Set<String> _busyPeers = <String>{};

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
    _uiTicker?.cancel();
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

  /// Copies the whole on-screen log, oldest-first (so it reads top-to-bottom
  /// like a transcript, unlike the newest-first on-screen list), with
  /// timestamps. Exists because transcribing a multi-line stack trace off a
  /// phone screen by hand — or screenshotting it — is exactly the kind of
  /// friction that shouldn't exist in debugging tooling.
  void _copyLogToClipboard() {
    final String text = _log.reversed
        .map((LogLine l) =>
            '${l.at.hour.toString().padLeft(2, '0')}:'
            '${l.at.minute.toString().padLeft(2, '0')}:'
            '${l.at.second.toString().padLeft(2, '0')}.'
            '${l.at.millisecond.toString().padLeft(3, '0')}  ${l.text}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    _say('log copied to clipboard (${_log.length} lines)');
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

    // Repaint only — no radio work here. Liveness comes from advertisement
    // reception in _onDiscovered; this just keeps the "Ns ago" text moving
    // and flips chips to stale once kPeerStaleAfter elapses.
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

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
        _lastSeenAt.clear();
        _lastRssi.clear();
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
    final bool isNew = !_peers.containsKey(key);
    final String label = _labelOf(args, key);

    // EVERY advertisement updates liveness, not just the first. An earlier
    // version early-returned here for known peers, which threw away exactly
    // the signal the range test needs — see the _lastSeenAt comment block.
    final bool wasStale = _isStale(key);
    setState(() {
      _peers[key] = args.peripheral;
      _peerNames[key] = label;
      _lastSeenAt[key] = DateTime.now();
      _lastRssi[key] = args.rssi;
    });

    if (isNew) {
      final Duration? elapsed = _discoveryStartedAt == null
          ? null
          : DateTime.now().difference(_discoveryStartedAt!);
      _say('FOUND $label  rssi=${args.rssi}'
          '${elapsed == null ? '' : '  after ${elapsed.inMilliseconds}ms'}');
    } else if (wasStale) {
      // Only log the transition back, never every advertisement — otherwise
      // the log is 100% liveness noise within seconds.
      _say('$label back in range  rssi=${args.rssi}');
    }
  }

  /// True when we have not heard an advertisement from this peer recently.
  /// Also true for a peer we have never heard from at all.
  bool _isStale(String key) {
    final DateTime? seen = _lastSeenAt[key];
    if (seen == null) return true;
    return DateTime.now().difference(seen) > kPeerStaleAfter;
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

  /// Live in-range chip for one peer — the thing to watch while walking the
  /// Day 4 range test. Green means we heard an advertisement within
  /// kPeerStaleAfter; red means we have not.
  ///
  /// RSSI is shown live because it is the *leading* indicator: it sags well
  /// before the chip goes red, so you can see the edge of range approaching
  /// rather than only noticing once you are past it. Rough guide on these
  /// devices: -50s comfortable, -70s fine, -80s getting marginal, -90s about
  /// to drop. Note RSSI is noisy — a body, a wall, or pocketing the phone
  /// moves it 10+ dB — so treat it as a trend, not a distance readout.
  Widget _buildPeerStatusChip(String key) {
    final String name = _peerNames[key] ?? key;
    final DateTime? seen = _lastSeenAt[key];
    final bool live = !_isStale(key);
    final int? rssi = _lastRssi[key];

    final String detail = seen == null
        ? 'not heard yet'
        : live
            ? 'rssi ${rssi ?? '?'}'
            : '${DateTime.now().difference(seen).inSeconds}s ago';

    return Chip(
      avatar: Icon(
        live ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
        color: Colors.white,
        size: 18,
      ),
      label: Text('$name — $detail'),
      backgroundColor: live ? Colors.green[700] : Colors.red[700],
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _peers.keys.map(_buildPeerStatusChip).toList(),
                  ),
                  // Load-bearing warning, not decoration: liveness is now
                  // derived purely from advertisement reception, so with
                  // scanning off every chip goes red regardless of whether
                  // the peers are actually there.
                  if (!_scanning)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Scanning is OFF — status below is stale. Liveness '
                        'comes from hearing adverts, so keep Scan running '
                        'during range tests.',
                        style: TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
          SwitchListTile(
            title: const Text('Relay received messages'),
            subtitle: const Text('Turn OFF on the middle phone to prove '
                'A and C cannot reach each other directly'),
            value: _relayEnabled,
            onChanged: (bool v) => setState(() => _relayEnabled = v),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('Log (${_log.length})',
                    style: Theme.of(context).textTheme.labelMedium),
              ),
              TextButton.icon(
                onPressed: _log.isEmpty ? null : _copyLogToClipboard,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy log'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            // Long-press-drag-to-select across lines, in addition to the
            // Copy log button — useful for grabbing just one error line
            // without the whole log.
            child: SelectionArea(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (BuildContext context, int i) {
                  final LogLine line = _log[i];
                  return ListTile(
                    dense: true,
                    title: SelectableText(line.text,
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
