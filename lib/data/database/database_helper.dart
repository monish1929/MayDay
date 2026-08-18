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
        payload             BLOB    NOT NULL,   -- CBOR
        resolution_method   INTEGER,            -- NULL while ACTIVE
        resolved_by         TEXT,
        hop_limit           INTEGER NOT NULL,
        display_lifetime_ms INTEGER,            -- NULL for sos / sosProxy
        created_at_logical  INTEGER NOT NULL,
        archived_at_logical INTEGER
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
    final db = await instance.database;
    db.close();
  }
}
