// lib/mesh/seen_message_cache.dart

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../data/database/database_helper.dart';

/// De-dup cache for envelope `msgId`s — CLAIM_SCHEMA.md §9.3 step 1.
///
/// Backed by the `seen_messages` table so it survives a restart: a device
/// that rebooted mid-flood would otherwise re-accept and re-relay everything
/// still circulating.
///
/// **This works only because `msgId` is preserved across relay hops.** One
/// transmission keeps one id all the way out; a fresh id is minted only when
/// the originator sends the claim again. If every hop re-generated it, a
/// message reaching a device via five neighbours would look like five
/// distinct messages, each stored and re-relayed — a broadcast storm rather
/// than a flood, which is the density failure mode `PERSON_A.md` carries as
/// an open question for Week 5.
class SeenMessageCache {
  /// Cap on retained ids. The table cannot grow forever on a device that
  /// stays in a busy mesh for days (§10.2 budgets storage overall).
  ///
  /// Provisional: the right number depends on real traffic rates, which
  /// Phase 0 has not measured. Deliberately generous — evicting too eagerly
  /// re-admits messages still in flight, and the cost of that is duplicate
  /// relays, not lost data.
  static const int defaultMaxEntries = 2000;

  final DatabaseHelper _dbHelper;
  final int maxEntries;

  SeenMessageCache({
    DatabaseHelper? databaseHelper,
    this.maxEntries = defaultMaxEntries,
  }) : _dbHelper = databaseHelper ?? DatabaseHelper.instance;

  Future<bool> hasSeen(Uint8List msgId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'seen_messages',
      columns: const ['msg_id'],
      where: 'msg_id = ?',
      whereArgs: [msgId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Records [msgId] as seen and evicts the oldest entries if over cap.
  ///
  /// `seen_at` is wall-clock milliseconds. That is safe *here* specifically:
  /// it never leaves the device, is never compared against another device's
  /// clock, and does not order claims — §4's "no wall clock" rule is about
  /// claim causality, which this is not. Eviction still orders by rowid
  /// rather than by this column, so a clock jump cannot corrupt the cache.
  Future<void> record(Uint8List msgId) async {
    final db = await _dbHelper.database;
    await db.insert(
      'seen_messages',
      {
        'msg_id': msgId,
        'seen_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _evictIfNeeded(db);
  }

  Future<int> count() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM seen_messages');
    return (result.first['c'] as int?) ?? 0;
  }

  Future<void> _evictIfNeeded(Database db) async {
    final total = await count();
    if (total <= maxEntries) return;

    // Oldest-first by insertion order. rowid, not seen_at: insertion order is
    // a fact, whereas a device's clock can jump.
    await db.rawDelete(
      '''
      DELETE FROM seen_messages
      WHERE rowid IN (
        SELECT rowid FROM seen_messages ORDER BY rowid ASC LIMIT ?
      )
      ''',
      [total - maxEntries],
    );
  }
}
