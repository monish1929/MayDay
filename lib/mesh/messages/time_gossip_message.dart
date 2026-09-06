// lib/mesh/messages/time_gossip_message.dart

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../data/models/logical_clock.dart';
import 'body_codec.dart';

/// `kind: 6` — two devices that meet exchange clock readings, PERSON_A.md
/// Wk4 D4.
///
/// **This is not network time sync, and the difference is the whole point.**
/// CLAUDE.md §1.2 rules out NTP because there is no network to sync against.
/// Gossip is the opposite arrangement: nobody is authoritative, no reading is
/// trusted on its own, and what comes out is a median across everyone this
/// device has met — with volunteers weighted higher, computed in `data/`
/// (`MeshTimeGossip`), not here.
///
/// **What the result may be used for:** rendering "about 2 hours ago" next to
/// a pin. **What it may never be used for:** ordering, merging, decay, or
/// claim identity. Those are logical clocks only (§4), and CLAUDE.md §1.2
/// rules out time-bucketed claim ids precisely because clocks drift with no
/// sync — two identical events would produce different ids and never merge.
///
/// Gossip is **never relayed** (`RoutingPolicy` returns `doNotRelay`). A clock
/// reading is evidence about the pair of devices that exchanged it and
/// nothing else; forwarding one secondhand would let a single skewed clock
/// propagate as though many devices had independently observed it.
class TimeGossipMessage {
  /// The sender's wall-clock reading, milliseconds since the Unix epoch.
  ///
  /// Yes, a wall clock — that is the quantity being gossiped about. It is
  /// **evidence**, not a time source: it is compared against the receiver's
  /// own reading to produce an offset sample, and never used to order
  /// anything (see the class comment). The §4 prohibition is on wall clocks
  /// deciding causality, which this deliberately does not do.
  final int wallClockMs;

  /// The sender's logical clock at the moment of the reading, so a sample can
  /// be attributed and ordered against that device's other messages (§4).
  final LogicalClock logicalClock;

  const TimeGossipMessage({
    required this.wallClockMs,
    required this.logicalClock,
  });

  Uint8List encode() {
    return Uint8List.fromList(cbor.encode(CborList([
      // CborInt, not CborSmallInt: epoch milliseconds is ~1.7e12 and does not
      // fit the small-int encoding. Everything else on the wire is a count or
      // an enum index and does.
      CborInt(BigInt.from(wallClockMs)),
      logicalClock.toCbor(),
    ])));
  }

  static BodyDecodeResult<TimeGossipMessage> decode(List<int> bytes) {
    final list = BodyFields.readArray(bytes, 2);
    if (list == null) return const BodyDecodeError('expected a 2-field array');

    final wallField = list[0];
    if (wallField is! CborInt) {
      return const BodyDecodeError('wallClockMs: expected an integer');
    }
    final wallClockMs = wallField.toInt();
    if (wallClockMs < 0) {
      return const BodyDecodeError('wallClockMs: negative');
    }

    final clock = BodyFields.clock(list[1]);
    if (clock == null) return const BodyDecodeError('logicalClock: malformed');

    return BodyDecodeOk(TimeGossipMessage(
      wallClockMs: wallClockMs,
      logicalClock: clock,
    ));
  }
}
