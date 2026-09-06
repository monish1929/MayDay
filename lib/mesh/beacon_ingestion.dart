// lib/mesh/beacon_ingestion.dart

import '../data/time/device_clock.dart';
import '../identity/keypair.dart';
import '../identity/node_trust.dart';
import 'envelope.dart';
import 'message_handler.dart';
import 'messages/beacon_message.dart';
import 'messages/body_codec.dart';
import 'relay_queue.dart';
import 'routing_policy.dart';
import 'volunteer_gradient.dart';

/// Reads the clock without pinning the receive path to the real one.
///
/// Local milliseconds only — never compared against another device's clock
/// and never used to order anything (see [VolunteerGradient.expireBefore]).
typedef LocalClockMs = int Function();

/// Applies `kind: 5` volunteer beacons — PERSON_A.md Wk4 D3.
///
/// Turns "a signed beacon arrived through neighbour X having travelled two
/// hops" into a gradient entry the relay queue can steer by. Two things it
/// deliberately does **not** do:
///
/// - **It never makes anyone a volunteer.** A beacon is a self-assertion:
///   anyone can sign "volunteer here". Volunteer status comes only from the
///   vouch web ([NodeTrustDirectory]), and a beacon from a key that is not
///   already trusted is dropped rather than believed. Without that rule, one
///   phone shouting a beacon becomes the preferred route for every SOS in
///   range — an attacker's ideal position, and a trivial one to reach.
///
/// - **It never touches `claimTrust`.** A volunteer being nearby says nothing
///   about whether any claim is true (CLAUDE.md §2.2, §2.4).
class BeaconIngestion implements MessageHandler {
  final VolunteerGradient gradient;
  final NodeTrustDirectory trust;
  final DeviceClock deviceClock;
  final RoutingPolicy policy;
  final LocalClockMs now;

  /// Shortest interval between relaying two beacons from the same volunteer.
  ///
  /// **PROVISIONAL**, like every other timing number here — Wk4 D5 tunes it
  /// against real battery data that does not exist yet. Beacons are periodic
  /// and self-replacing: a dropped one is corrected by the next, so they must
  /// never crowd out claim traffic. This is the second of two guards; the
  /// first is `RoutingPolicy` classing them as droppable, which puts them in
  /// the queue class that yields to everything else.
  static const Duration defaultMinRelayInterval = Duration(seconds: 20);

  final Duration minRelayInterval;

  /// Local ms of the last relay per volunteer device id.
  final Map<String, int> _lastRelayedMs = {};

  BeaconIngestion({
    required this.gradient,
    required this.trust,
    required this.deviceClock,
    this.policy = const RoutingPolicy(),
    this.minRelayInterval = defaultMinRelayInterval,
    LocalClockMs? now,
  }) : now = now ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<MessageOutcome> handle(Envelope envelope, RelayTarget? from) async {
    final decoded = BeaconMessage.decode(envelope.body);
    if (decoded is BodyDecodeError<BeaconMessage>) {
      return MessageOutcome.dropped('beacon: ${decoded.reason}');
    }
    final beacon = (decoded as BodyDecodeOk<BeaconMessage>).body;

    // A beacon says "route SOS traffic this way". Believing an unverified key
    // would let any phone volunteer itself to the front of the queue.
    final signer = await trust.capabilitiesOf(envelope.originPubKey);
    if (!signer.isVolunteer) {
      return const MessageOutcome.dropped('beacon: signer is not a volunteer');
    }

    await deviceClock.observeReceive(beacon.logicalClock);

    final volunteerId =
        DeviceKeyPair.deviceIdForPublicKey(envelope.originPubKey);

    final hops = BeaconMessage.hopsTravelled(
      initialHopLimit:
          policy.initialHopLimitForKind(EnvelopeKind.volunteerBeacon),
      envelopeHopLimit: envelope.hopLimit,
    );

    if (from == null) {
      // No neighbour to attribute the route to, so there is nothing to
      // record. Reached only by a locally originated beacon replayed through
      // the receive path — a device does not need a gradient entry pointing
      // at itself.
      return const MessageOutcome.relayOnly('beacon: no inbound peer');
    }

    final changed = gradient.record(
      volunteerDeviceId: volunteerId,
      viaPeerId: from.peerId,
      hops: hops,
      beaconSeq: beacon.beaconSeq,
      nowMs: now(),
    );

    final relay = _mayRelay(volunteerId);
    return MessageOutcome(
      accepted: changed,
      relay: relay,
      reason: relay ? null : 'beacon rate-limited',
    );
  }

  /// Rate limit, per volunteer rather than globally.
  ///
  /// Global would be wrong: two volunteers beaconing at once are two facts
  /// the gradient needs, and silencing one because the other just spoke
  /// hides a whole route.
  bool _mayRelay(String volunteerId) {
    final nowMs = now();
    final last = _lastRelayedMs[volunteerId];
    if (last != null && nowMs - last < minRelayInterval.inMilliseconds) {
      return false;
    }
    _lastRelayedMs[volunteerId] = nowMs;
    return true;
  }
}
