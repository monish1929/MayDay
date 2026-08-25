// lib/mesh/relay_queue.dart

import '../data/enums.dart';
import 'envelope.dart';
import 'routing_policy.dart';

/// A neighbour this device can currently write to.
///
/// `isVolunteer` is set from the volunteer beacon (Week 4). Until beaconing
/// exists every peer arrives here as a non-volunteer, which degrades send
/// ordering to insertion order — correct, just not yet preferential.
class RelayTarget {
  final String peerId;
  final bool isVolunteer;

  const RelayTarget({required this.peerId, this.isVolunteer = false});
}

/// Writes one envelope to one neighbour. Returns false if the write failed;
/// it must not throw — a neighbour walking out of range mid-write is ordinary
/// on this transport, not an error condition.
typedef PeerSender = Future<bool> Function(RelayTarget target, Envelope envelope);

/// Send-priority class. Lower sorts first.
///
/// The split that matters is [critical] vs everything else: [critical] is
/// never dropped under any queue pressure (CLAUDE.md §1.1), so it cannot
/// share a bucket with traffic that is.
enum RelayPriority {
  /// SOS, proxy SOS, and resolutions. Never dropped, never deprioritised.
  critical,

  /// Hazards, corroborations, vouches, revocations. Flooded, but yields to
  /// [critical] and is shed before it if memory is genuinely exhausted.
  standard,

  /// Resource claims and beacons. The droppable class.
  droppable,
}

class _QueuedRelay {
  final Envelope envelope;
  final RelayPriority priority;

  /// Insertion order, so sorting stays stable within a priority class and the
  /// queue behaves FIFO for equal-priority traffic.
  final int seq;

  const _QueuedRelay(this.envelope, this.priority, this.seq);
}

/// Relay queue with volunteer-first send ordering and backpressure —
/// PERSON_A.md Week 2 Day 5.
///
/// Sits behind the receive pipeline's `relay` callback: the pipeline decides
/// relay is permissible, [RoutingPolicy] decides whether it happens, and this
/// decides in what order and what gives way when the radio falls behind.
///
/// **Why the radio falls behind at all:** one BLE write is a connect, a
/// negotiate, a write, a disconnect — hundreds of milliseconds. A dense mesh
/// can generate messages faster than that. Without a bounded queue the
/// backlog grows until the device dies, which on a phone budgeted for 72
/// hours is a failure that arrives silently.
class RelayQueue {
  /// Cap on droppable traffic. Small on purpose — this is the class that
  /// exists to be sacrificed, and a deep queue of stale resource counts is
  /// worse than no queue at all.
  static const int defaultMaxDroppable = 64;

  /// Cap on standard traffic. Generous, because shedding it is already a
  /// degraded state we would rather not reach.
  static const int defaultMaxStandard = 512;

  final RoutingPolicy policy;
  final PeerSender sender;
  final int maxDroppable;
  final int maxStandard;

  final List<_QueuedRelay> _queue = [];
  int _seq = 0;

  /// Count of messages shed by backpressure, by class. Exposed because a
  /// non-zero droppable count is normal and a non-zero standard count means
  /// the mesh is in trouble — the two must be distinguishable in the field.
  int droppedDroppable = 0;
  int droppedStandard = 0;

  RelayQueue({
    required this.sender,
    this.policy = const RoutingPolicy(),
    this.maxDroppable = defaultMaxDroppable,
    this.maxStandard = defaultMaxStandard,
  });

  int get length => _queue.length;

  /// Queues an envelope for relay, or drops it per policy.
  ///
  /// Returns true if it was queued. A false return is not an error — it means
  /// routing policy said this message does not travel onward, or backpressure
  /// shed it.
  bool enqueue(Envelope envelope) {
    final decision = policy.decide(envelope);
    if (decision == RelayDecision.doNotRelay) return false;

    final priority = _priorityFor(envelope, decision);
    _queue.add(_QueuedRelay(envelope, priority, _seq++));
    return _applyBackpressure();
  }

  /// Sheds traffic if a class is over its cap. Returns whether the envelope
  /// just enqueued survived.
  ///
  /// **[RelayPriority.critical] is never counted and never shed.** There is no
  /// cap to exceed and no branch here that can remove one. CLAUDE.md §1.1 is
  /// absolute: no eviction rule may cause an unresolved SOS to disappear from
  /// a device holding it, and a queue cap is an eviction rule. If a future
  /// refactor "unifies" the three classes under one limit, that unification is
  /// the bug — however tidy it looks.
  bool _applyBackpressure() {
    var survived = true;

    for (final cls in [RelayPriority.droppable, RelayPriority.standard]) {
      final cap = cls == RelayPriority.droppable ? maxDroppable : maxStandard;
      var over = _queue.where((q) => q.priority == cls).length - cap;
      if (over <= 0) continue;

      // Oldest-first. A stale resource count has already been superseded by
      // whatever is behind it in the queue; the newest is the one worth
      // sending.
      while (over > 0) {
        final index = _queue.indexWhere((q) => q.priority == cls);
        if (index < 0) break;
        final evicted = _queue.removeAt(index);
        // The just-enqueued item always carries the highest seq issued.
        if (evicted.seq == _seq - 1) survived = false;
        if (cls == RelayPriority.droppable) {
          droppedDroppable++;
        } else {
          droppedStandard++;
        }
        over--;
      }
    }

    return survived;
  }

  /// Sends everything queued, highest priority first, to every target.
  ///
  /// Targets are ordered volunteers-first: when several neighbours can carry a
  /// message, the one most likely to act on it goes first. If the radio dies
  /// partway through a drain, the sends that did happen were the ones that
  /// mattered most.
  Future<int> drain(List<RelayTarget> targets) async {
    if (targets.isEmpty || _queue.isEmpty) return 0;

    final ordered = [...targets]..sort((a, b) {
        if (a.isVolunteer == b.isVolunteer) return 0;
        return a.isVolunteer ? -1 : 1;
      });

    _queue.sort((a, b) {
      final byPriority = a.priority.index.compareTo(b.priority.index);
      return byPriority != 0 ? byPriority : a.seq.compareTo(b.seq);
    });

    final batch = [..._queue];
    _queue.clear();

    var sent = 0;
    for (final item in batch) {
      for (final target in ordered) {
        if (await sender(target, item.envelope)) sent++;
      }
    }
    return sent;
  }

  RelayPriority _priorityFor(Envelope envelope, RelayDecision decision) {
    if (decision == RelayDecision.selective) return RelayPriority.droppable;

    // A resolution clears an SOS. It rides in the same class as the SOS it
    // answers — a resolution shed under pressure leaves a rescued person
    // showing as still trapped, and volunteers still being sent.
    if (envelope.kind == EnvelopeKind.resolution) return RelayPriority.critical;

    if (envelope.kind == EnvelopeKind.claim) {
      final type = RoutingPolicy.peekClaimType(envelope.body);
      if (type == ClaimType.sos || type == ClaimType.sosProxy) {
        return RelayPriority.critical;
      }
      // An unclassifiable claim is treated as critical, matching
      // RoutingPolicy.decide()'s fallback: if this version cannot tell what it
      // is, it does not get to be the thing that shed an SOS.
      if (type == null) return RelayPriority.critical;
    }

    return RelayPriority.standard;
  }
}
