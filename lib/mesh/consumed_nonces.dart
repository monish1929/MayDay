// lib/mesh/consumed_nonces.dart

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../data/database/database_helper.dart';

/// Nonces already spent closing a rescue — CLAUDE.md §6.2, PERSON_A.md Wk4 D4.
///
/// **The hole this closes.** A rescue QR proves presence by pairing a nonce
/// generated at the moment of display with the requester's signature over
/// `sosId || nonce`. That makes each code specific to one display — but
/// specific is not the same as *single-use*. Nothing stopped the same code
/// being presented twice: photograph a trapped person's screen, walk away,
/// and hand the picture to a second volunteer later. Both signatures verify,
/// because they are the same two signatures; the envelope de-dup cache does
/// not catch it, because the replay is a genuinely new envelope with a new
/// `msgId` and a fresh counter-signature; and last-write-wins by logical
/// clock actively *prefers* the replay, because it arrives later.
///
/// So the nonce has to be remembered. A resolution whose `(sosId, nonce)` has
/// already been applied here is refused — which is exactly the line between a
/// replay and the legitimate case the resolution path already allows: two
/// volunteers genuinely both scanning means two separate displays, and
/// therefore two different nonces.
///
/// **What this does not do, stated plainly (CLAUDE.md §9).** It makes a
/// rescue code single-use; it does not make it unforgeable to a bystander.
/// Someone who photographs a QR *before* any volunteer scans it still holds a
/// valid first use, and no offline check can tell that apart from the genuine
/// scan — the signatures are identical either way. What is closed here is the
/// far more likely path: a code that already closed a rescue being presented
/// again, to a second volunteer or a second device, to re-close or re-open
/// something that was already settled.
///
/// **Rows are never evicted.** Every other bounded store in `mesh/` caps
/// itself; this one does not, because forgetting a spent nonce re-opens the
/// replay window for exactly the rescue that was already closed. The cost of
/// remembering is 80-odd bytes per resolution this device ever saw, and a
/// device sees one resolution per rescue — a bounded, small number even
/// across a long response. Compare that with §1.1's direction of travel: the
/// failure we refuse to risk is the one that loses a person.
class ConsumedNonceStore {
  final DatabaseHelper _dbHelper;

  ConsumedNonceStore({DatabaseHelper? databaseHelper})
      : _dbHelper = databaseHelper ?? DatabaseHelper.instance;

  /// True if this exact code has already closed this exact SOS here.
  Future<bool> isConsumed(String sosId, List<int> nonce) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'consumed_resolution_nonces',
      where: 'sos_id = ? AND nonce = ?',
      whereArgs: [sosId, Uint8List.fromList(nonce)],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Records a nonce as spent.
  ///
  /// IGNORE rather than REPLACE: the row carries no payload beyond its own
  /// existence, so a second write of the same pair is a no-op either way, and
  /// IGNORE says that plainly.
  Future<void> consume(String sosId, List<int> nonce) async {
    final db = await _dbHelper.database;
    await db.insert(
      'consumed_resolution_nonces',
      {'sos_id': sosId, 'nonce': Uint8List.fromList(nonce)},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<int> count() async {
    final db = await _dbHelper.database;
    final rows = await db
        .rawQuery('SELECT COUNT(*) AS c FROM consumed_resolution_nonces');
    return (rows.first['c'] as int?) ?? 0;
  }
}
