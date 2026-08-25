// lib/mesh/mesh_bootstrap.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/database/claim_repository.dart';
import '../data/time/device_clock.dart';
import '../identity/keypair.dart';
import 'ble_mesh_transport.dart';
import 'claim_ingestion.dart';
import 'mesh_node.dart';
import 'mesh_transport.dart';

/// Why the mesh did not come up. Returned rather than thrown: a phone with
/// Bluetooth switched off is a normal state to be in, not a crash.
enum MeshStartFailure {
  /// The user declined one of the Android 12+ BLE permissions.
  permissionsDenied,

  /// The radio itself refused — Bluetooth off, adapter wedged, or the GATT
  /// server would not start.
  radioUnavailable,
}

class MeshStartResult {
  final MeshNode? node;
  final MeshStartFailure? failure;

  /// Present when [failure] is [MeshStartFailure.permissionsDenied]: exactly
  /// which ones, so the UI can say something more useful than "permission
  /// denied".
  final List<Permission> denied;

  const MeshStartResult.started(MeshNode this.node)
      : failure = null,
        denied = const [];

  const MeshStartResult.failed(this.failure, {this.denied = const []})
      : node = null;

  bool get running => node != null;
}

/// Brings the mesh up: permissions, identity, store, radio, node.
///
/// Everything below the UI is assembled here so `main.dart` needs one call and
/// no knowledge of how the layers fit together. Owned by `mesh/` (A) rather
/// than living in `ui/` — wiring the radio to the store is not C's concern,
/// and putting it in a widget would drag transport setup into the widget tree.
class MeshBootstrap {
  /// How often queued messages are pushed to neighbours.
  ///
  /// **Not the duty-cycle scheduler.** That is Week 4 work and has to be tuned
  /// against real battery numbers, which Phase 0 has not produced. This is a
  /// plain fixed-interval drain so messages actually leave the device during
  /// the Day 4 two-phone run — deliberately simple, deliberately temporary.
  static const Duration flushInterval = Duration(seconds: 5);

  /// The running node, once [start] has succeeded.
  ///
  /// A holder rather than an injected dependency because `ui/` is C's and the
  /// mock-to-real swap (PERSON_C.md Wk2 D1) has not happened yet. When the UI
  /// reads claims from B's store directly this should go — it is a seam for
  /// the Day 4 bring-up, not an architecture.
  static MeshNode? node;

  /// The Android 12+ BLE permissions.
  ///
  /// ACCESS_FINE_LOCATION is **deliberately not here.** The manifest declares
  /// it `maxSdkVersion="30"` to match `neverForLocation` on BLUETOOTH_SCAN, so
  /// on API 31+ it is correctly unrequestable — and Phase 0 hit a real bug
  /// where the spike asked for it unconditionally and treated the denial as
  /// fatal, which made the app refuse to start on a perfectly healthy phone
  /// (Docs/PERSON_A.md Wk1 D1-2).
  ///
  /// Consequence worth knowing: on Android 11 and below, BLE scanning still
  /// needs runtime location permission, and that path is **not implemented and
  /// not tested** — the team's test hardware is API 33. If the app has to
  /// support API ≤30, that is a separate, deliberate piece of work.
  static const List<Permission> requiredPermissions = [
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
  ];

  /// Constructs and starts the node.
  ///
  /// [transport] is injectable so a harness can drive the whole stack without
  /// a radio; leave it null for the real BLE transport.
  static Future<MeshStartResult> start({MeshTransport? transport}) async {
    _log('starting');

    final denied = await _requestPermissions();
    if (denied.isNotEmpty) {
      // Logged, not swallowed. An earlier version returned this result to a
      // caller that ignored it, so a mesh that never came up was completely
      // invisible — the app looked healthy and simply had no radio. On a
      // phone with no console, an unlogged failure is an undiagnosable one.
      _log('NOT STARTED: permissions denied: ${denied.join(', ')}');
      return MeshStartResult.failed(
        MeshStartFailure.permissionsDenied,
        denied: denied,
      );
    }

    // Provisional identity: the seed is stored in SharedPreferences in
    // plaintext, and secure storage is explicitly not built yet. Flagged as an
    // open question on Docs/PERSON_A.md — do not let this become the shipped
    // key handling by default.
    final keyPair = await DeviceKeyPair.loadOrCreateProvisional();

    final node = MeshNode(
      transport: transport ?? BleMeshTransport(),
      keyPair: keyPair,
      ingestion: ClaimIngestion(
        repository: ClaimRepository(),
        // The Lamport clock is keyed to this device's own identity, which is
        // derived from the keypair — never from a BLE address, which Android
        // rotates.
        deviceClock: DeviceClock(keyPair.deviceId),
      ),
    );

    try {
      await node.start();
    } catch (e) {
      // Bluetooth off, adapter wedged, GATT server refused, authorization
      // declined. All recoverable by the user, none of them a reason to take
      // the app down — the map and the local store still work with no radio at
      // all. The reason is printed because "the radio did not come up" is not
      // an actionable message; "authorization refused" is.
      _log('NOT STARTED: radio unavailable: $e');
      return const MeshStartResult.failed(MeshStartFailure.radioUnavailable);
    }

    MeshBootstrap.node = node;
    _log('started as device ${keyPair.deviceId}');

    Timer.periodic(flushInterval, (_) async {
      final sent = await node.flush();
      // Printed every tick, including the quiet ones. On a phone with no
      // console, "nothing is arriving" and "everything is arriving and being
      // rejected" look identical from the map — the counters are the only way
      // to tell them apart during the two-phone run. Read with:
      //   adb logcat -s flutter
      _log('peers=${node.transport.peers.length} sent=$sent ${node.stats}');
    });
    return MeshStartResult.started(node);
  }

  /// Deliberately `debugPrint` rather than `dart:developer`'s `log`.
  ///
  /// `developer.log` goes to the VM service and does **not** reach `adb
  /// logcat`, which made the first Day 4 bring-up attempt look like total
  /// silence. Anything meant to be read off a phone in the field has to go
  /// through print.
  static void _log(String message) => debugPrint('[mayday.mesh] $message');

  static Future<List<Permission>> _requestPermissions() async {
    final statuses = await requiredPermissions.request();
    return statuses.entries
        .where((entry) => !entry.value.isGranted)
        .map((entry) => entry.key)
        .toList();
  }
}
