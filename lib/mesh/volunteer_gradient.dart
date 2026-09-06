// lib/mesh/volunteer_gradient.dart

/// One neighbour's standing as a route toward a volunteer.
class GradientRoute {
  /// The neighbour this volunteer was heard through. For a volunteer that is
  /// itself a direct neighbour, this is that peer and [hops] is 0.
  final String viaPeerId;

  /// How many hops the beacon travelled to get here. Derived from what is
  /// left of the envelope's `hopLimit` — see [BeaconMessage.hopsTravelled]
  /// for why it cannot be a counter inside the signed body.
  final int hops;

  /// The beacon sequence this route was learned from. Freshness with no
  /// clock: a beacon carrying a lower sequence than one already held is
  /// stale, however long it took to arrive.
  final int beaconSeq;

  /// Local monotonic milliseconds when this was recorded — see
  /// [VolunteerGradient.expireBefore] for why a wall clock is safe here.
  final int observedAtMs;

  const GradientRoute({
    required this.viaPeerId,
    required this.hops,
    required this.beaconSeq,
    required this.observedAtMs,
  });
}

/// "A volunteer is ~3 hops away via this neighbour" — PERSON_A.md Wk4 D3.
///
/// **The replacement for directional relay, which cannot work.** BLE gives no
/// directional information at all, so a device cannot aim a message at
/// anything. What it *can* do is remember which neighbour a volunteer's
/// beacon came through and how far it travelled, and send that way first.
/// Same flood, different queue order — the flood itself is untouched, so
/// nothing stops reaching anyone (CLAUDE.md §1.1).
///
/// **Deliberately in memory, never persisted.** A gradient describes where
/// people were standing, and people move. Reloading yesterday's gradient
/// after a restart would send SOS traffic confidently toward a volunteer who
/// left hours ago — worse than having no preference at all, because the
/// device would stop looking. Compare `SeenMessageCache`, which *is*
/// persisted, because a message id is a fact that does not go stale.
class VolunteerGradient {
  /// How long a route stays usable without a fresh beacon.
  ///
  /// **PROVISIONAL.** The right value is a function of beacon interval and
  /// how fast volunteers actually move, and neither has been measured — the
  /// beacon interval itself is still untuned against battery (Wk4 D5). Erring
  /// short on purpose: an expired entry costs send ordering, a stale one
  /// costs a misrouted rescue.
  static const Duration defaultEntryLifetime = Duration(minutes: 5);

  final Duration entryLifetime;

  /// Best known route per volunteer device id.
  final Map<String, GradientRoute> _routes = {};

  VolunteerGradient({this.entryLifetime = defaultEntryLifetime});

  int get length => _routes.length;

  /// Records a beacon arrival. Returns true if it changed the gradient.
  ///
  /// A route is replaced when the beacon is fresher (higher sequence), or
  /// when an equally fresh one arrived by a shorter path. Ordering by
  /// sequence first matters: a beacon that took a slow four-hop route can
  /// easily arrive after a newer one-hop beacon, and letting it win would
  /// point the gradient at the longer path.
  bool record({
    required String volunteerDeviceId,
    required String viaPeerId,
    required int hops,
    required int beaconSeq,
    required int nowMs,
  }) {
    final existing = _routes[volunteerDeviceId];
    if (existing != null) {
      if (beaconSeq < existing.beaconSeq) return false;
      if (beaconSeq == existing.beaconSeq && hops >= existing.hops) {
        return false;
      }
    }

    _routes[volunteerDeviceId] = GradientRoute(
      viaPeerId: viaPeerId,
      hops: hops,
      beaconSeq: beaconSeq,
      observedAtMs: nowMs,
    );
    return true;
  }

  /// Drops routes older than [entryLifetime].
  ///
  /// `nowMs` is wall-clock milliseconds, which is safe *here specifically*:
  /// it never leaves the device, is never compared against another device's
  /// clock, and orders nothing. CLAIM_SCHEMA.md §4's no-wall-clock rule is
  /// about claim causality, which this is not. A clock jump costs at worst
  /// one round of forgotten routes, which the next beacon restores.
  void expireBefore(int nowMs) {
    final cutoff = nowMs - entryLifetime.inMilliseconds;
    _routes.removeWhere((_, route) => route.observedAtMs < cutoff);
  }

  /// Removes every route learned through a neighbour.
  ///
  /// Called when a peer disconnects: the volunteer three hops behind it has
  /// not moved, but this device can no longer reach them that way, and a
  /// route through a neighbour that is gone is exactly the stale entry the
  /// class comment says is worse than nothing.
  void forgetPeer(String peerId) {
    _routes.removeWhere((_, route) => route.viaPeerId == peerId);
  }

  /// Fewest hops to any known volunteer through this neighbour, or null if
  /// nothing is known to lie that way.
  ///
  /// Null is a real answer, not a failure: most neighbours in a sparse mesh
  /// have no volunteer behind them, and ordering treats "unknown" as worse
  /// than any known distance but still perfectly sendable.
  int? hopsVia(String peerId) {
    int? best;
    for (final route in _routes.values) {
      if (route.viaPeerId != peerId) continue;
      if (best == null || route.hops < best) best = route.hops;
    }
    return best;
  }

  /// Whether this neighbour is itself a volunteer — a beacon from it arrived
  /// having travelled zero hops.
  bool isDirectVolunteer(String peerId) {
    return _routes.values
        .any((r) => r.viaPeerId == peerId && r.hops == 0);
  }

  /// Every volunteer currently reachable, nearest first. For diagnostics —
  /// on a phone with no console, "the gradient is empty" and "the gradient
  /// points the wrong way" look identical from the map.
  List<MapEntry<String, GradientRoute>> get routes {
    final entries = _routes.entries.toList()
      ..sort((a, b) => a.value.hops.compareTo(b.value.hops));
    return entries;
  }

  @override
  String toString() => 'VolunteerGradient(${_routes.length} routes: '
      '${routes.map((e) => '${e.key.substring(0, 6)}@${e.value.hops}h').join(' ')})';
}
