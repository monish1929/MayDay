// lib/mesh/mesh_transport.dart

import 'dart:typed_data';

import 'relay_queue.dart';

/// Bytes that arrived from a neighbour, with the peer they came from.
///
/// `bytes` is entirely untrusted: it is whatever a stranger's phone wrote to
/// our characteristic. Nothing upstream of the receive pipeline may assume it
/// is a well-formed envelope, or even valid CBOR.
class InboundFrame {
  final RelayTarget from;
  final Uint8List bytes;

  const InboundFrame({required this.from, required this.bytes});
}

/// The radio, as the rest of `mesh/` sees it.
///
/// Exists so the wiring above it — pipeline, ingestion, relay queue — can be
/// tested with no radio and no device. CLAUDE.md §6.1 requires two physical
/// devices for mesh code, and that stays true for the BLE implementation; it
/// does not mean the *wiring* has to be untestable until then. Every bug
/// caught against a fake transport is one nobody chases across two phones.
abstract class MeshTransport {
  /// Frames as they arrive. Never emits an error for malformed input — a
  /// stranger's garbage is expected traffic, and the pipeline decides its fate.
  Stream<InboundFrame> get inbound;

  /// Neighbours currently writable. Changes as devices come and go; a peer
  /// present here can still fail a write a moment later.
  List<RelayTarget> get peers;

  /// Writes to one neighbour. Returns false on failure rather than throwing —
  /// a peer walking out of range mid-write is ordinary on this transport.
  Future<bool> send(RelayTarget target, Uint8List bytes);

  Future<void> start();

  Future<void> stop();
}
