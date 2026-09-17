// lib/mesh/messages/beacon_message.dart

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../data/models/logical_clock.dart';
import 'body_codec.dart';

/// `kind: 5` — a signed "volunteer here", PERSON_A.md Wk4 D3.
///
/// **This replaces directional relay, which cannot work.** v1 of the design
/// said nodes should "preferentially relay toward known Volunteer
/// directions", but BLE gives no directional information whatsoever, and in a
/// full flood there is nothing left to prefer anyway. What does work is a
/// gradient: a volunteer broadcasts periodically, every device that hears it
/// learns "a volunteer is ~N hops away via this neighbour", and send ordering
/// follows the gradient. Same flood, different queue order.
///
/// The body is deliberately tiny. Beacons are periodic and every one of them
/// competes with claim traffic for the same radio.
class BeaconMessage {
  /// Which beacon this is from this volunteer, monotonically increasing.
  ///
  /// Freshness that does not depend on any clock: a beacon with a lower
  /// sequence than one already held is stale, whatever path it arrived by and
  /// however long it took. Without it, a beacon that took a slow four-hop
  /// route could overwrite a fresh one-hop entry and point the gradient the
  /// wrong way.
  final int beaconSeq;

  /// The volunteer's logical clock when it emitted this beacon.
  final LogicalClock logicalClock;

  const BeaconMessage({
    required this.beaconSeq,
    required this.logicalClock,
  });

  /// **There is deliberately no hop-count field in this body.**
  ///
  /// A counter that every relay increments would have to change in flight,
  /// and the body is exactly what `originSig` covers (§9.1) — so the first
  /// device to increment it would invalidate the signature and every device
  /// after that would drop the beacon. This is the same reason the envelope
  /// signature excludes `hopLimit`.
  ///
  /// Hop distance is therefore *derived* from what is left of the envelope's
  /// `hopLimit`, which is the field designed to change per hop. See
  /// [hopsTravelled].
  static int hopsTravelled({
    required int initialHopLimit,
    required int envelopeHopLimit,
  }) {
    final travelled = initialHopLimit - envelopeHopLimit;
    // Never negative: a stranger can put any hopLimit it likes on the wire,
    // and a negative distance would sort that beacon to the front of the
    // gradient — making the least trustworthy packet the most preferred route.
    return travelled < 0 ? 0 : travelled;
  }

  Uint8List encode() {
    return Uint8List.fromList(cbor.encode(CborList([
      CborSmallInt(beaconSeq),
      logicalClock.toCbor(),
    ])));
  }

  static BodyDecodeResult<BeaconMessage> decode(List<int> bytes) {
    final list = BodyFields.readArray(bytes, 2);
    if (list == null) return const BodyDecodeError('expected a 2-field array');

    final seq = BodyFields.nonNegativeInt(list[0]);
    if (seq == null) {
      return const BodyDecodeError('beaconSeq: expected a non-negative int');
    }

    final clock = BodyFields.clock(list[1]);
    if (clock == null) return const BodyDecodeError('logicalClock: malformed');

    return BodyDecodeOk(BeaconMessage(beaconSeq: seq, logicalClock: clock));
  }
}
