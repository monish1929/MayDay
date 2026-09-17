// lib/mesh/pending_resolutions.dart

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../data/database/database_helper.dart';
import '../data/enums.dart';
import '../data/models/logical_clock.dart';
import 'messages/resolution_message.dart';

/// A resolution held because the SOS it resolves has not arrived yet, plus
/// the volunteer key that counter-signed it.
class PendingResolution {
  final ResolutionMessage message;

  /// Raw Ed25519 public key of the counter-signing volunteer — the envelope's
  /// `originPubKey`. Kept because the envelope is gone by the time this is
  /// replayed, and `resolvedByVolunteerId` has to come from somewhere.
  final Uint8List resolverPubKey;

  const PendingResolution({
    required this.message,
    required this.resolverPubKey,
  });
}

/// Resolutions waiting for their SOS — PERSON_A.md Wk3 D3, the last bullet.
///
/// **A resolution can outrun the claim it resolves.** The SOS floods from
/// wherever the person is; the resolution floods from wherever the volunteer
/// was standing when they scanned the QR. On a device on the far side of the
/// mesh those are two different journeys, and there is no rule that says the
/// shorter one started first — a phone that was out of range when the SOS
/// went out can easily meet the resolution first.
///
/// Dropping it is not an option. The claim would then arrive afterwards and
/// sit ACTIVE **forever** on that phone: nothing else ever clears an SOS
/// (§2.3 — SOS never decays), so volunteers would keep being dispatched to
/// someone who was rescued hours ago. That is CLAUDE.md §1.1 read in the
/// other direction — a rule that silently discards life-critical data.
///
/// Persisted rather than held in memory for exactly the same reason: a device
/// that restarts between the two arrivals must not forget.
class PendingResolutionStore {
  /// Cap on parked resolutions.
  ///
  /// Every row here is a signed message for an SOS this device has never
  /// seen, so an attacker can mint them freely. Bounded, but generously: the
  /// realistic count is "resolutions that outran their claim", which is small,
  /// and evicting one that was genuine costs a claim stuck ACTIVE forever.
  static const int defaultMaxEntries = 512;

  final DatabaseHelper _dbHelper;
  final int maxEntries;

  PendingResolutionStore({
    DatabaseHelper? databaseHelper,
    this.maxEntries = defaultMaxEntries,
  }) : _dbHelper = databaseHelper ?? DatabaseHelper.instance;

  Future<void> park(
    ResolutionMessage message, {
    required List<int> resolverPubKey,
  }) async {
    final db = await _dbHelper.database;
    await db.insert(
      'pending_resolutions',
      {
        'sos_id': message.sosId,
        'nonce': message.nonce,
        'requester_pub_key': message.requesterPubKey,
        'requester_sig': message.requesterSig,
        'resolver_pub_key': Uint8List.fromList(resolverPubKey),
        'method': message.method.index,
        'clock_device_id': message.resolvedAtLogical.deviceId,
        'clock_counter': message.resolvedAtLogical.counter,
      },
      // REPLACE: one SOS has one resolution. A second arriving for the same
      // id is either the same message by another path, or a competing resolve
      // that the claim-side logical-clock ordering settles when it is applied.
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _evictIfNeeded(db);
  }

  /// The resolution parked for this claim id, if any.
  Future<PendingResolution?> take(String sosId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'pending_resolutions',
      where: 'sos_id = ?',
      whereArgs: [sosId],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    final methodIndex = row['method'] as int;
    if (methodIndex < 0 || methodIndex >= ResolutionMethod.values.length) {
      // Only reachable if the table were written by something other than
      // [park] — which validated the enum on the way in. Discarded rather
      // than crashing the receive path.
      await discard(sosId);
      return null;
    }

    return PendingResolution(
      resolverPubKey: Uint8List.fromList(row['resolver_pub_key'] as List<int>),
      message: ResolutionMessage(
        sosId: row['sos_id'] as String,
        nonce: Uint8List.fromList(row['nonce'] as List<int>),
        requesterPubKey:
            Uint8List.fromList(row['requester_pub_key'] as List<int>),
        requesterSig: Uint8List.fromList(row['requester_sig'] as List<int>),
        method: ResolutionMethod.values[methodIndex],
        resolvedAtLogical: LogicalClock(
          deviceId: row['clock_device_id'] as String,
          counter: row['clock_counter'] as int,
        ),
      ),
    );
  }

  /// Removes a parked resolution once it has been applied to a real claim.
  Future<void> discard(String sosId) async {
    final db = await _dbHelper.database;
    await db.delete(
      'pending_resolutions',
      where: 'sos_id = ?',
      whereArgs: [sosId],
    );
  }

  Future<int> count() async {
    final db = await _dbHelper.database;
    final rows =
        await db.rawQuery('SELECT COUNT(*) AS c FROM pending_resolutions');
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> _evictIfNeeded(Database db) async {
    final total = await count();
    if (total <= maxEntries) return;

    // Oldest-first by insertion order (rowid), not by any clock: insertion
    // order is a local fact, whereas a device's clock can jump and the
    // logical clocks in these rows belong to other devices entirely.
    //
    // **This evicts resolutions, never claims.** §1.1 forbids evicting an
    // active SOS; a parked resolution is an unverifiable message about a
    // claim this device does not hold, which is a different thing. If this
    // ever grows a branch that touches the `claims` table, that branch is the
    // bug.
    await db.rawDelete(
      '''
      DELETE FROM pending_resolutions
      WHERE rowid IN (
        SELECT rowid FROM pending_resolutions ORDER BY rowid ASC LIMIT ?
      )
      ''',
      [total - maxEntries],
    );
  }
}
