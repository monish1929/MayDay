// lib/identity/vouch_registry.dart

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../data/database/database_helper.dart';
import '../mesh/messages/revocation_message.dart';
import '../mesh/messages/vouch_message.dart';
import 'node_trust.dart';

/// Why a vouch or revocation did not take effect. Returned, never thrown —
/// every one of these arrives from a stranger's phone over the radio, so they
/// are ordinary traffic rather than exceptions (CLAIM_SCHEMA.md §9.3).
enum TrustWriteRejection {
  /// The signer is not campaign-verified.
  ///
  /// MAYDAY_PROJECT_CONTEXT.md §2.2: **provisional nodes cannot vouch.** This
  /// is the rule that bounds the damage from one compromised phone — without
  /// it, a stolen volunteer key mints a provisional volunteer, who mints five
  /// more, and every device in the mesh believes all of them.
  voucherNotVerified,

  /// The voucher has already spoken for as many people as its cap allows.
  vouchCapExceeded,

  /// A revocation signed by someone who is not the voucher it claims to
  /// cancel. Anyone could otherwise strip any volunteer of their status with
  /// one shouted message.
  notTheOriginalVoucher,

  /// A revocation for a vouch this device has never seen. Refused rather than
  /// parked: unlike a resolution, a revocation with nothing to revoke changes
  /// nothing, and the vouch it refers to is re-evaluated against the
  /// revocation set whenever it does arrive.
  unknownVouch,

  /// Superseded by something already held with a higher logical clock — a
  /// stale message that took a slow path (§4).
  staleClock,

  /// A device vouching for itself, which is an assertion rather than
  /// evidence.
  selfVouch,

  /// The voucher is past the hard storage bound. See
  /// [VouchRegistry.maxStoredVouchesPerVoucher].
  storageBound,
}

class TrustWriteResult {
  final bool applied;
  final TrustWriteRejection? rejection;

  const TrustWriteResult.applied()
      : applied = true,
        rejection = null;

  const TrustWriteResult.rejected(TrustWriteRejection this.rejection)
      : applied = false;
}

/// The web of trust, as this one device sees it — PERSON_A.md Wk4 D1–D2.
///
/// Holds every vouch and revocation the device has heard and answers "what is
/// this key allowed to do" from them. There is no server to ask and no
/// directory to look anything up in: each device reaches its own conclusion
/// from messages it received and verified itself, which is the only way any
/// of this works offline.
///
/// **Where the authority actually comes from.** Every standing vouch traces
/// back to a campaign-verified key in `trust_anchors`, signed at registration
/// before the disaster. With that table empty — which it is in every build
/// today, because issuing campaign credentials is B's Phase 4 work — no vouch
/// can be accepted from anyone. Nothing here quietly falls back to trusting
/// an unverified signer to keep the feature demonstrable: a trust registry
/// with a convenience bypass is not a trust registry.
class VouchRegistry implements NodeTrustDirectory {
  /// Hard bound on rows kept per voucher, well above the cap of 5.
  ///
  /// The cap itself is enforced by *ranking*, not by refusing writes, because
  /// mesh delivery is out of order — a voucher's first vouch can easily
  /// arrive sixth. So the device stores what it hears and decides which five
  /// count. This bound exists only so a rogue campaign-verified key cannot
  /// fill the disk by signing vouches forever.
  static const int maxStoredVouchesPerVoucher = 32;

  final DatabaseHelper _dbHelper;

  /// Answers are cached because this is consulted on the receive path, once
  /// per message, and each answer is otherwise several queries. Dropped whole
  /// on any write rather than invalidated per key: one vouch changes the
  /// answer for its vouchee and for nobody else, and the precision would buy
  /// nothing measurable.
  final Map<String, NodeCapabilities> _cache = {};

  VouchRegistry({DatabaseHelper? databaseHelper})
      : _dbHelper = databaseHelper ?? DatabaseHelper.instance;

  static String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Seeds a campaign-verified key.
  ///
  /// The loader that reads a real campaign credential off a volunteer's
  /// device is `identity/`'s Phase 4 work and does not exist yet. This is the
  /// seam it will write through, and what tests use to stand up a root of
  /// trust.
  Future<void> addTrustAnchor(List<int> publicKey, {String? label}) async {
    final db = await _dbHelper.database;
    await db.insert(
      'trust_anchors',
      {'pub_key': Uint8List.fromList(publicKey), 'label': label},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _cache.clear();
  }

  Future<bool> isTrustAnchor(List<int> publicKey) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'trust_anchors',
      columns: const ['pub_key'],
      where: 'pub_key = ?',
      whereArgs: [Uint8List.fromList(publicKey)],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Applies a verified vouch. The envelope signature was already checked
  /// upstream (§9.3 step 2); what is checked here is whether the signer was
  /// *entitled* to say it.
  ///
  /// `voucherSig` is the envelope's `originSig`, stored beside the row so the
  /// vouch stays independently verifiable once the envelope is gone.
  Future<TrustWriteResult> recordVouch({
    required List<int> voucherPubKey,
    required List<int> voucherSig,
    required VouchMessage vouch,
  }) async {
    if (_hex(voucherPubKey) == _hex(vouch.voucheePubKey)) {
      // Self-vouching is an assertion, not evidence. Rejected explicitly
      // rather than left to fall out of the cap arithmetic by accident.
      return const TrustWriteResult.rejected(TrustWriteRejection.selfVouch);
    }

    // §2.2, the rule that bounds blast radius: only campaign-verified nodes
    // may vouch. A `vouchedProvisional` signer is refused here even though
    // its signature is perfectly good.
    final voucher = await capabilitiesOf(voucherPubKey);
    if (!voucher.canVouch) {
      return const TrustWriteResult.rejected(
        TrustWriteRejection.voucherNotVerified,
      );
    }

    final db = await _dbHelper.database;
    final existing = await db.query(
      'vouches',
      where: 'voucher_pub_key = ?',
      whereArgs: [Uint8List.fromList(voucherPubKey)],
    );

    final voucheeHex = _hex(vouch.voucheePubKey);
    final alreadyForThisVouchee = existing.any(
      (r) => _hex(r['vouchee_pub_key'] as List<int>) == voucheeHex,
    );

    if (!alreadyForThisVouchee &&
        existing.length >= maxStoredVouchesPerVoucher) {
      return const TrustWriteResult.rejected(TrustWriteRejection.storageBound);
    }

    await db.insert(
      'vouches',
      {
        'voucher_pub_key': Uint8List.fromList(voucherPubKey),
        'vouchee_pub_key': Uint8List.fromList(vouch.voucheePubKey),
        'vouch_index': vouch.vouchIndex,
        'vouch_cap': vouch.vouchCap,
        'voucher_sig': Uint8List.fromList(voucherSig),
        'clock_device_id': vouch.logicalClock.deviceId,
        'clock_counter': vouch.logicalClock.counter,
      },
      // IGNORE, not REPLACE: the first account of a vouch is the one that
      // counts. Replacing would let a voucher rewrite its own logical clock
      // by re-sending, and that clock is what a revocation is ordered against.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _cache.clear();

    // Stored, but it only *counts* if it lands inside the voucher's capped
    // set, which is decided by ranking at read time in [_effectiveVouchees].
    // Reported back so a caller can log the difference.
    final effective = await _effectiveVouchees(voucherPubKey);
    if (!effective.contains(voucheeHex)) {
      return const TrustWriteResult.rejected(
        TrustWriteRejection.vouchCapExceeded,
      );
    }

    return const TrustWriteResult.applied();
  }

  /// Applies a verified revocation — PERSON_A.md Wk4 D2.
  Future<TrustWriteResult> recordRevocation({
    required List<int> revokerPubKey,
    required RevocationMessage revocation,
  }) async {
    final db = await _dbHelper.database;

    // "Revocation signed by someone other than the original voucher →
    // rejected." Without this, one message from any device in the mesh
    // removes any volunteer — a denial of service aimed squarely at the
    // people doing the responding.
    final vouch = await db.query(
      'vouches',
      where: 'voucher_pub_key = ? AND vouchee_pub_key = ?',
      whereArgs: [
        Uint8List.fromList(revokerPubKey),
        Uint8List.fromList(revocation.revokedPubKey),
      ],
      limit: 1,
    );
    if (vouch.isEmpty) {
      // Two different failures are distinguished here so a field log can tell
      // an attack from ordinary out-of-order delivery: a revoker who never
      // vouched for this key, versus a vouch this device has not heard yet.
      final anyVouchForTarget = await db.query(
        'vouches',
        where: 'vouchee_pub_key = ?',
        whereArgs: [Uint8List.fromList(revocation.revokedPubKey)],
        limit: 1,
      );
      return TrustWriteResult.rejected(
        anyVouchForTarget.isEmpty
            ? TrustWriteRejection.unknownVouch
            : TrustWriteRejection.notTheOriginalVoucher,
      );
    }

    final existing = await db.query(
      'revocations',
      where: 'revoker_pub_key = ? AND revoked_pub_key = ?',
      whereArgs: [
        Uint8List.fromList(revokerPubKey),
        Uint8List.fromList(revocation.revokedPubKey),
      ],
      limit: 1,
    );
    if (existing.isNotEmpty &&
        (existing.first['clock_counter'] as int) >=
            revocation.logicalClock.counter) {
      // "Devices apply the most recent valid revocation" (§2.2). One that
      // took a slow path must not overwrite a later one already held.
      return const TrustWriteResult.rejected(TrustWriteRejection.staleClock);
    }

    await db.insert(
      'revocations',
      {
        'revoker_pub_key': Uint8List.fromList(revokerPubKey),
        'revoked_pub_key': Uint8List.fromList(revocation.revokedPubKey),
        'reason': revocation.reason.index,
        'clock_device_id': revocation.logicalClock.deviceId,
        'clock_counter': revocation.logicalClock.counter,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _cache.clear();
    return const TrustWriteResult.applied();
  }

  @override
  Future<NodeCapabilities> capabilitiesOf(List<int> publicKey) async {
    final key = _hex(publicKey);
    final cached = _cache[key];
    if (cached != null) return cached;

    final NodeCapabilities result;
    if (await isTrustAnchor(publicKey)) {
      result = const NodeCapabilities(
        trust: NodeTrust.campaignVerified,
        standingVouches: 0,
      );
    } else {
      final standing = await _standingVouchers(publicKey);
      result = NodeCapabilities(
        trust: standing.isEmpty
            ? NodeTrust.unverified
            : NodeTrust.vouchedProvisional,
        standingVouches: standing.length,
      );
    }

    _cache[key] = result;
    return result;
  }

  /// The distinct campaign-verified vouchers currently standing behind a key.
  ///
  /// A vouch counts only if all three hold: the voucher is campaign-verified,
  /// the vouch is inside that voucher's capped set, and no revocation from
  /// that voucher outranks it by logical clock.
  Future<Set<String>> _standingVouchers(List<int> voucheePubKey) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'vouches',
      where: 'vouchee_pub_key = ?',
      whereArgs: [Uint8List.fromList(voucheePubKey)],
    );

    final voucheeHex = _hex(voucheePubKey);
    final standing = <String>{};

    for (final row in rows) {
      final voucherKey = row['voucher_pub_key'] as List<int>;

      // Only an anchor's vouch carries weight. Checked directly against the
      // anchor table rather than through capabilitiesOf(), so a vouch chain
      // cannot recurse: a provisional node cannot vouch (§2.2), so the web is
      // exactly one level deep and must stay that way.
      if (!await isTrustAnchor(voucherKey)) continue;

      if (!(await _effectiveVouchees(voucherKey)).contains(voucheeHex)) {
        continue;
      }

      final revocation = await db.query(
        'revocations',
        where: 'revoker_pub_key = ? AND revoked_pub_key = ?',
        whereArgs: [
          Uint8List.fromList(voucherKey),
          Uint8List.fromList(voucheePubKey),
        ],
        limit: 1,
      );
      if (revocation.isNotEmpty) {
        final revokedAt = revocation.first['clock_counter'] as int;
        final vouchedAt = row['clock_counter'] as int;
        // A revocation cancels vouches at or below its own counter. A genuine
        // re-vouch signed afterwards therefore stands again — "most recent
        // wins" has to cut both ways, or a revoked volunteer could never be
        // reinstated, there being no network to do it over.
        if (revokedAt >= vouchedAt) continue;
      }

      standing.add(_hex(voucherKey));
    }
    return standing;
  }

  /// Which of a voucher's vouches fall inside its cap.
  ///
  /// Ranked by logical clock, then by vouchee key as a deterministic
  /// tie-break, and the first `vouchCap` win. **Ranking rather than
  /// first-come:** messages arrive out of order on a mesh, so "the first five
  /// this device happened to hear" would give two devices two different
  /// answers about the same voucher. Ordering by the clock the voucher itself
  /// signed makes every device agree without anyone coordinating.
  Future<Set<String>> _effectiveVouchees(List<int> voucherPubKey) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'vouches',
      where: 'voucher_pub_key = ?',
      whereArgs: [Uint8List.fromList(voucherPubKey)],
    );
    if (rows.isEmpty) return const {};

    final sorted = [...rows]..sort((a, b) {
        final byClock =
            (a['clock_counter'] as int).compareTo(b['clock_counter'] as int);
        if (byClock != 0) return byClock;
        return _hex(a['vouchee_pub_key'] as List<int>)
            .compareTo(_hex(b['vouchee_pub_key'] as List<int>));
      });

    // The cap the vouches themselves carry (§2.2), bounded by what this
    // device is willing to honour. `VouchMessage.decode` already refuses
    // anything larger on the wire; this is the second half of the same guard,
    // and takes the *smallest* cap the voucher ever signed so it cannot raise
    // its own limit later by sending one generous vouch.
    final declaredCap = sorted
        .map((r) => r['vouch_cap'] as int)
        .fold(VouchMessage.maxVouchCap, (int a, int b) => a < b ? a : b);
    final cap = declaredCap.clamp(1, VouchMessage.maxVouchCap);

    return sorted
        .take(cap)
        .map((r) => _hex(r['vouchee_pub_key'] as List<int>))
        .toSet();
  }

  /// Convenience for the receive path: does the mesh treat the signer of this
  /// message as a volunteer?
  Future<bool> isVolunteer(List<int> publicKey) async {
    return (await capabilitiesOf(publicKey)).isVolunteer;
  }

  /// Drops the answer cache. Needed only when something outside this class
  /// has written to the tables — tests do.
  void invalidateCache() => _cache.clear();
}
