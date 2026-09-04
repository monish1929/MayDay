// lib/mesh/ble_mesh_transport.dart

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'mesh_transport.dart';
import 'relay_queue.dart';

/// The service every MayDay node advertises and scans for. Fixed and
/// identical on every device — it is how a node recognises another node.
final UUID kMayDayServiceUuid =
    UUID.fromString('6d61790d-0001-4d65-9368-000000000001');

/// The one writable characteristic. One envelope is one write to this.
final UUID kEnvelopeCharUuid =
    UUID.fromString('6d61790d-0002-4d65-9368-000000000002');

/// Real BLE transport — the Phase 0 spike's proven GATT setup, moved into
/// production code.
///
/// Every node runs both roles at once: peripheral, so neighbours can find it
/// and write to it, and central, so it can find and write to them. That dual
/// role is what makes this a mesh rather than a hub, and it is why the
/// package choice was forced (Docs/PERSON_A.md §9).
///
/// **This class cannot be unit tested.** CLAUDE.md §6.1 is explicit that mesh
/// code needs two physical devices and that an emulator does not count. The
/// logic above it is tested against a fake [MeshTransport]; what lives here is
/// exactly the part that has to be proven on hardware.
class BleMeshTransport implements MeshTransport {
  /// Every native call is wrapped in this.
  ///
  /// Not decoration — confirmed at the edge of range in Phase 0: `connect()`
  /// can hang for 30+ seconds rather than failing fast, silently blocking
  /// every later send to that peer for the whole hang. A native BLE call that
  /// never returns must not be able to wedge the node.
  static const Duration callTimeout = Duration(seconds: 8);

  /// Shorter, because these run at startup and a hang here means the node
  /// never comes up at all.
  static const Duration setupTimeout = Duration(seconds: 5);

  /// Authorization is the one call that legitimately waits on a **person**.
  ///
  /// `authorize()` can raise a system permission dialog, and [setupTimeout]
  /// applied to it meant the Future was abandoned five seconds in — long
  /// before anyone could read the prompt, let alone tap it. The mesh then
  /// reported "radio unavailable" on a phone whose radio was fine and whose
  /// user was still deciding.
  ///
  /// Generous rather than absent: a wedged adapter must still fail eventually
  /// rather than leave the node half-started forever. The rule is that a
  /// timeout bounds a hung *native call*, never a human's reaction time.
  static const Duration authorizeTimeout = Duration(minutes: 2);

  /// Phase 0 measured 512-byte writes succeeding repeatedly at a negotiated
  /// ATT MTU of 517, against an envelope budget of 400 bytes. The default MTU
  /// is 23, which allows a 20-byte write — every envelope would fail without
  /// this negotiation.
  static const int desiredMtu = 517;

  final CentralManager _central;
  final PeripheralManager _peripheral;

  /// How long a neighbour stays in [peers] after its last advertisement.
  ///
  /// Android rotates BLE peripheral addresses for privacy, so a phone that
  /// never moved reappears under a new id and the old one is dead forever
  /// (PERSON_A.md §7 recorded this from Phase 0). Without eviction the peer
  /// list only grows, and the relay queue drains onto handles that cannot be
  /// written to — which is exactly how a claim goes missing while the log
  /// cheerfully reports more peers than there are phones in the room.
  ///
  /// Generous next to the spike's 4s liveness chip: that drove a UI colour,
  /// this decides whether we still try to deliver an SOS. Dropping a
  /// reachable neighbour costs a delivery; keeping a dead one costs one
  /// failed write.
  static const Duration peerStaleAfter = Duration(seconds: 30);

  final _inbound = StreamController<InboundFrame>.broadcast();
  final Map<String, Peripheral> _peers = {};

  /// Last time each peer was heard advertising.
  final Map<String, DateTime> _peerLastSeen = {};

  /// Peers with a write already in flight.
  ///
  /// Phase 0: two overlapping `connect()` calls to the same peer destabilised
  /// the plugin on real hardware. A second write to a busy peer is skipped
  /// rather than queued — the relay queue still holds the message, so the
  /// next drain retries it.
  final Set<String> _busyPeers = {};

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool _started = false;

  BleMeshTransport({CentralManager? central, PeripheralManager? peripheral})
      : _central = central ?? CentralManager(),
        _peripheral = peripheral ?? PeripheralManager();

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  /// Currently discovered neighbours.
  ///
  /// `peerId` is the BLE peripheral uuid, which Android rotates for privacy.
  /// It is a routing handle and **nothing else** — never an identity. Who sent
  /// a claim is settled by the Ed25519 key inside the envelope, never by the
  /// address it arrived from (CLAUDE.md §2.5).
  @override
  List<RelayTarget> get peers {
    _evictStalePeers();
    return _peers.keys
        .map((id) => RelayTarget(peerId: id))
        .toList(growable: false);
  }

  void _evictStalePeers() {
    final cutoff = DateTime.now().subtract(peerStaleAfter);
    _peerLastSeen.removeWhere((id, seen) {
      if (seen.isAfter(cutoff)) return false;
      _peers.remove(id);
      _busyPeers.remove(id);
      return true;
    });
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // Both managers must be authorized before ANY radio call.
    //
    // Without this, `addService()` and `startAdvertising()` never complete and
    // never throw — the node looks like it started, logs nothing, and simply
    // does not exist on the air. Found on hardware during Day 4 bring-up: the
    // GATT server registered, then silence. The Phase 0 spike had these two
    // lines and they were the one thing not carried across.
    await _ensureAuthorized(_central, 'central');
    await _ensureAuthorized(_peripheral, 'peripheral');
    debugPrint('[mayday.mesh] authorized, adding GATT service...');

    _subscriptions.add(
      _peripheral.characteristicWriteRequested.listen(_onWriteRequested),
    );
    _subscriptions.add(_central.discovered.listen(_onDiscovered));

    await _startAdvertising();
    debugPrint('[mayday.mesh] advertising, starting discovery...');
    await _central
        .startDiscovery(serviceUUIDs: [kMayDayServiceUuid])
        .timeout(setupTimeout);
    debugPrint('[mayday.mesh] discovery started');
  }

  /// Gets a manager into [BluetoothLowEnergyState.poweredOn], asking the user
  /// only if it is actually needed.
  ///
  /// **Do not "simplify" this back to an unconditional `authorize()`.** That
  /// call is `ActivityCompat.requestPermissions()` plus a stored callback which
  /// only fires from `onRequestPermissionsResult`. When the permissions are
  /// already granted — which they are, because MeshBootstrap asks for them
  /// through permission_handler first — Android shows no dialog, delivers no
  /// result to this plugin's listener, and the returned Future never completes.
  /// The node then hangs on startup with the radio in perfect working order.
  /// Cost a bring-up cycle on hardware to find; the symptom is a log that stops
  /// dead at "authorizing central...".
  ///
  /// Checking `state` avoids the request entirely in the normal case: it reads
  /// `checkSelfPermission` directly and reports [BluetoothLowEnergyState
  /// .unauthorized] only when a permission really is missing — which is exactly
  /// when a dialog will genuinely appear and a human genuinely has to answer.
  Future<void> _ensureAuthorized(
    BluetoothLowEnergyManager manager,
    String label,
  ) async {
    // The plugin reports `unknown` until the native side has attached. Poll
    // briefly rather than acting on a state that has not been determined yet.
    final deadline = DateTime.now().add(setupTimeout);
    while (manager.state == BluetoothLowEnergyState.unknown &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    debugPrint('[mayday.mesh] $label state=${manager.state.name}');

    switch (manager.state) {
      case BluetoothLowEnergyState.poweredOn:
        return;

      case BluetoothLowEnergyState.unauthorized:
        // A permission really is missing, so this will raise a dialog and wait
        // on a person — hence the long timeout.
        debugPrint('[mayday.mesh] $label unauthorized, prompting...');
        if (!await manager.authorize().timeout(authorizeTimeout)) {
          throw StateError('$label manager: authorization declined');
        }
        return;

      // Named rather than lumped into a generic failure: "Bluetooth is off" is
      // something the user can fix in two taps, and telling them that is the
      // whole difference between a dead app and a recoverable one.
      case BluetoothLowEnergyState.poweredOff:
        throw StateError('$label manager: Bluetooth is turned off');

      case BluetoothLowEnergyState.unsupported:
        throw StateError('$label manager: BLE not supported on this device');

      case BluetoothLowEnergyState.unknown:
        throw StateError('$label manager: state still unknown after '
            '${setupTimeout.inSeconds}s');
    }
  }

  Future<void> _startAdvertising() async {
    final characteristic = GATTCharacteristic.mutable(
      uuid: kEnvelopeCharUuid,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );

    await _peripheral.removeAllServices().timeout(setupTimeout);
    await _peripheral
        .addService(GATTService(
          uuid: kMayDayServiceUuid,
          isPrimary: true,
          includedServices: [],
          characteristics: [characteristic],
        ))
        .timeout(setupTimeout);

    // DELIBERATELY no `name:` on this Advertisement.
    //
    // On Android that path calls BluetoothAdapter.setName(), which renames the
    // WHOLE PHONE's Bluetooth name — system-wide and persistently — then waits
    // for an ACTION_LOCAL_NAME_CHANGED broadcast to complete its Future. If the
    // adapter name already equals the requested name, Android fires no
    // broadcast, the Future never completes, and startAdvertising hangs
    // forever with no error. That cost most of a day in Phase 0
    // (PHASE0_MESH_FINDINGS.md §6). We need no name anyway: identity travels
    // inside the signed envelope.
    await _peripheral
        .startAdvertising(Advertisement(serviceUUIDs: [kMayDayServiceUuid]))
        .timeout(setupTimeout);
  }

  void _onDiscovered(DiscoveredEventArgs args) {
    final id = args.peripheral.uuid.toString();
    _peers[id] = args.peripheral;
    _peerLastSeen[id] = DateTime.now();
  }

  void _onWriteRequested(GATTCharacteristicWriteRequestedEventArgs args) {
    // Respond first. A central that is never answered blocks waiting for its
    // write to complete, and the node stops being able to accept anything
    // else from it.
    unawaited(_peripheral.respondWriteRequest(args.request));

    // Handed on exactly as received. This is untrusted input from a stranger's
    // phone; nothing here inspects, trusts, or repairs it. The receive
    // pipeline decides its fate (CLAIM_SCHEMA.md §9.3).
    _inbound.add(InboundFrame(
      from: RelayTarget(peerId: args.central.uuid.toString()),
      bytes: Uint8List.fromList(args.request.value),
    ));
  }

  @override
  Future<bool> send(RelayTarget target, Uint8List bytes) async {
    final peer = _peers[target.peerId];
    if (peer == null) return false;

    if (_busyPeers.contains(target.peerId)) {
      // Skipped, not queued — see _busyPeers. The relay queue still holds it.
      return false;
    }
    _busyPeers.add(target.peerId);

    try {
      await _writeOnce(peer, bytes).timeout(callTimeout);
      return true;
    } catch (e) {
      // Every failure mode is the same to the caller: a neighbour walked out
      // of range, the adapter refused, the write timed out. None of them are
      // exceptional on this transport, and none may propagate — an uncaught
      // throw on the send path takes the node down while an SOS is in the
      // queue behind it.
      //
      // But it is logged. A silent `return false` here meant a phone that
      // could receive and relay but never deliver looked identical to a phone
      // with nothing to say: `sent=0` and no reason anywhere. Android's GATT
      // errors are numbered for a reason (133 is not 257) and the number is
      // the whole diagnosis.
      debugPrint('[mayday.mesh] send FAILED to ${target.peerId}: $e');
      return false;
    } finally {
      _busyPeers.remove(target.peerId);
    }
  }

  Future<void> _writeOnce(Peripheral peer, Uint8List bytes) async {
    await _central.connect(peer);
    await _central.requestMTU(peer, mtu: desiredMtu);

    final services = await _central.discoverGATT(peer);
    final characteristic = services
        .firstWhere((s) => s.uuid == kMayDayServiceUuid)
        .characteristics
        .firstWhere((c) => c.uuid == kEnvelopeCharUuid);

    await _central.writeCharacteristic(
      peer,
      characteristic,
      value: bytes,
      // With response: we want the failure, not a silent drop. A write that
      // vanished looks identical to a delivered one otherwise, and at the
      // range edge that is exactly the distinction that matters.
      type: GATTCharacteristicWriteType.withResponse,
    );
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    // Each guarded separately: a failure stopping one must not leave the other
    // running. A node that stopped advertising but kept scanning is a battery
    // drain nobody can see.
    try {
      await _central.stopDiscovery().timeout(setupTimeout);
    } catch (_) {
      // Already stopped, or the adapter is gone. Nothing to recover.
    }
    try {
      await _peripheral.stopAdvertising().timeout(setupTimeout);
    } catch (_) {
      // As above.
    }

    _peers.clear();
    _peerLastSeen.clear();
    _busyPeers.clear();
    await _inbound.close();
  }
}
