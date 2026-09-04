// lib/data/database/database_helper.dart

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();

  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('mayday.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE claims (
        id                  TEXT PRIMARY KEY,
        type                INTEGER NOT NULL,
        origin_device_id    TEXT    NOT NULL,
        origin_sequence     INTEGER NOT NULL,
        clock_device_id     TEXT    NOT NULL,
        clock_counter       INTEGER NOT NULL,
        lat                 REAL    NOT NULL,
        lon                 REAL    NOT NULL,
        geohash_bucket      TEXT    NOT NULL,
        origin_signature    BLOB    NOT NULL,
        claim_trust         INTEGER NOT NULL,
        dispatch_priority   INTEGER NOT NULL,
        status              INTEGER NOT NULL,
        payload             BLOB    NOT NULL,   -- CBOR, per §8
        resolution_method   INTEGER,            -- NULL while ACTIVE
        resolved_by         TEXT,
        resolved_at_logical_device_id TEXT,     -- LogicalClock, NULL until resolved — see §4
        resolved_at_logical_counter   INTEGER,
        hop_limit           INTEGER NOT NULL,
        display_lifetime_ms INTEGER,            -- NULL for sos / sosProxy — see below
        created_at_logical_device_id  TEXT    NOT NULL,  -- LogicalClock, mandatory: every claim has a creation event — see §4
        created_at_logical_counter    INTEGER NOT NULL,
        last_confirmed_at_logical_device_id TEXT,        -- LogicalClock, NULL until first re-confirmation
        last_confirmed_at_logical_counter   INTEGER,
        archived_at_logical_device_id TEXT,     -- LogicalClock, NULL until archived
        archived_at_logical_counter   INTEGER
      );
    ''');

    await db.execute('CREATE INDEX idx_claims_status_type ON claims(status, type);');
    await db.execute('CREATE INDEX idx_claims_geohash     ON claims(geohash_bucket);');

    await db.execute('''
      CREATE TABLE corroborations (
        claim_id        TEXT    NOT NULL,
        device_id       TEXT    NOT NULL,
        hop_distance    INTEGER NOT NULL,
        signal_strength REAL,
        first_seen_via  TEXT,                   -- relaying device id, NULL if self-generated
        kind            INTEGER NOT NULL,       -- CorroborationKind
        is_volunteer    INTEGER NOT NULL,
        clock_counter   INTEGER NOT NULL,
        PRIMARY KEY (claim_id, device_id)
      );
    ''');

    await db.execute('''
      CREATE TABLE seen_messages (
        msg_id  BLOB PRIMARY KEY,
        seen_at INTEGER NOT NULL
      );
    ''');
  }

  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  /// Test seam only — drops the open handle and deletes the underlying file
  /// so each test starts against a freshly created schema. Never call this
  /// from app code: it destroys the claim store, and §1.1 says an active SOS
  /// is never silently discarded.
  Future<void> resetForTest() async {
    if (_database != null && _database!.isOpen) {
      try {
        await _database!.delete('claims');
        await _database!.delete('corroborations');
        await _database!.delete('seen_messages');
        return;
      } catch (_) {
        // Fall through to close and delete if table schemas changed
      }
    }
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
    final dbPath = join(await getDatabasesPath(), 'mayday.db');
    try {
      await deleteDatabase(dbPath);
    } catch (_) {}
  }
}
