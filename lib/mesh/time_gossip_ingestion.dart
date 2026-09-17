// lib/mesh/time_gossip_ingestion.dart

import '../data/models/logical_clock.dart';
import '../data/time/device_clock.dart';
import '../data/time/mesh_time.dart';
import '../identity/keypair.dart';
import '../identity/node_trust.dart';
import 'envelope.dart';
import 'message_handler.dart';
import 'messages/body_codec.dart';
import 'messages/time_gossip_message.dart';
import 'relay_queue.dart';

/// One observed difference between this device's clock and a neighbour's.
///
/// The raw material for the drift measurement PERSON_A.md Wk4 D4 asks for
/// ("measure real clock drift between our test devices over 24h") and the
/// input `data/` needs to compute a median.
class ClockSample {
  /// Device id of the neighbour, derived from the key that signed — never
  /// self-asserted, and never a BLE address, which Android rotates.
  final String peerDeviceId;

  /// `theirReading - ourReading`, in milliseconds. Positive means their clock
  /// is ahead of ours.
  final int offsetMs;

  /// Whether the mesh treats that peer as a volunteer. Passed through so the
  /// median in `data/` can weight volunteers higher, per Wk4 D4.
  final bool isVolunteer;

  final LogicalClock peerLogicalClock;

  const ClockSample({
    required this.peerDeviceId,
    required this.offsetMs,
    required this.isVolunteer,
    required this.peerLogicalClock,
  });

  @override
  String toString() =>
      '${peerDeviceId.substring(0, 6)} ${offsetMs >= 0 ? '+' : ''}${offsetMs}ms'
      '${isVolunteer ? ' (volunteer)' : ''}';
}

/// Applies `kind: 6` time gossip — PERSON_A.md Wk4 D4.
///
/// **This is not clock sync and must never become it.** CLAUDE.md §1.2 rules
/// out NTP because there is no network; it does not rule out two phones that
/// meet comparing notes. Nobody here is authoritative, no single reading is
/// believed, and the output is only ever used to render "about 2 hours ago"
/// beside a pin. Ordering, merging, decay and claim identity stay on logical
/// clocks (§4) — §1.2 rules out time-bucketed claim ids for exactly this
/// reason: clocks drift with no sync, so identical events would get different
/// ids and never merge.
///
/// The median itself is `data/`'s ([MeshTimeGossip]); this side collects the
/// readings and says who is a volunteer, which `data/` has no way to know.
class TimeGossipIngestion implements MessageHandler {
  final MeshTimeGossip meshTime;
  final NodeTrustDirectory trust;
  final DeviceClock deviceClock;

  /// This device's own wall-clock reading, for computing the offset. Injected
  /// so a test can produce a known drift without waiting a day for one.
  final int Function() localWallClockMs;

  /// Recent offset samples, newest last. In memory and bounded: this is
  /// diagnostic material for the Wk4 D4 drift number, not state the app
  /// depends on.
  static const int maxSamples = 64;
  final List<ClockSample> samples = [];

  TimeGossipIngestion({
    required this.meshTime,
    required this.trust,
    required this.deviceClock,
    int Function()? localWallClockMs,
  }) : localWallClockMs = localWallClockMs ?? _nowMs;

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<MessageOutcome> handle(Envelope envelope, RelayTarget? from) async {
    final decoded = TimeGossipMessage.decode(envelope.body);
    if (decoded is BodyDecodeError<TimeGossipMessage>) {
      return MessageOutcome.dropped('gossip: ${decoded.reason}');
    }
    final gossip = (decoded as BodyDecodeOk<TimeGossipMessage>).body;

    await deviceClock.observeReceive(gossip.logicalClock);

    final capabilities = await trust.capabilitiesOf(envelope.originPubKey);
    final sample = ClockSample(
      peerDeviceId: DeviceKeyPair.deviceIdForPublicKey(envelope.originPubKey),
      offsetMs: gossip.wallClockMs - localWallClockMs(),
      isVolunteer: capabilities.isVolunteer,
      peerLogicalClock: gossip.logicalClock,
    );

    samples.add(sample);
    if (samples.length > maxSamples) samples.removeAt(0);

    // Handed to `data/`, which owns what to do with a set of readings.
    //
    // **Known gap, flagged not papered over:** Wk4 D4 says that layer
    // "computes the median (volunteers weighted higher)", and `MeshTimeGossip`
    // currently does a running weighted average instead. Fixing it is a
    // `data/` change and therefore B's — CLAUDE.md §3.3 — so this side hands
    // over the reading and the volunteer flag it needs, and the median is
    // raised with B rather than reimplemented here.
    meshTime.receiveGossip(
      gossip.logicalClock,
      sample.offsetMs,
      sample.isVolunteer,
    );

    // **Never relayed** — `RoutingPolicy` says the same thing, and this is
    // the second half of that decision rather than a duplicate of it. A clock
    // reading is evidence about the two devices that exchanged it; forwarding
    // one secondhand would let a single skewed clock propagate as though many
    // devices had independently observed it, which is precisely the failure a
    // median is supposed to prevent.
    return const MessageOutcome.acceptedNoRelay();
  }

  /// Mean absolute offset across the samples held, or null if there are none.
  /// Read off a phone during the 24-hour drift run.
  double? get meanAbsoluteOffsetMs {
    if (samples.isEmpty) return null;
    final total = samples.fold<int>(0, (sum, s) => sum + s.offsetMs.abs());
    return total / samples.length;
  }
}
