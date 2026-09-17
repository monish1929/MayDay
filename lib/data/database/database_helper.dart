// lib/data/database/database_helper.dart

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();

  static Database? _database;

  DatabaseHelper._init();

  /// Bumped to 2 by PERSON_A.md Wk3 D3 / Wk4 D1-D2, which added the three
  /// tables in [_createMeshIdentityTables].
  ///
  /// A device that has been through a disaster already holds claims. An
  /// upgrade that dropped and recreated the store would delete active SOS
  /// records, which CLAUDE.md §1.1 forbids outright — so [_upgradeDB] only
  /// ever adds tables, and there is deliberately no destructive branch in it.
  static const int schemaVersion = 3;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('mayday.db');
    return _database!;
  }

  /// Set only by [resetForTest]. When non-null the store is in-memory, which
  /// keeps concurrently-running test files from sharing one database file.
  static String? _overridePath;

  Future<Database> _initDB(String filePath) async {
    final path = _overridePath ?? join(await getDatabasesPath(), filePath);

    return await openDatabase(
      path,
      version: schemaVersion,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
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

    await _createMeshIdentityTables(db);
    await _createConsumedNonceTable(db);
  }

  /// Additive only. See [schemaVersion] for why there is no other kind.
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createMeshIdentityTables(db);
    }
    if (oldVersion < 3) {
      await _createConsumedNonceTable(db);
    }
  }

  /// Tables owned by `mesh/` and `identity/` rather than by the claim model —
  /// the same arrangement `seen_messages` already has.
  ///
  /// **Not yet in CLAIM_SCHEMA.md §10, and that is a known gap, not an
  /// oversight.** §10 is a shared contract with no single owner (CLAUDE.md
  /// §3.3), so recording these needs the three-person sync §12 requires.
  /// Flagged in the PR and in PERSON_A.md; do not quietly edit §10 alone.
  Future<void> _createMeshIdentityTables(Database db) async {
    // A resolution can outrun the SOS it resolves: it floods from wherever
    // the volunteer was standing, while the original travelled from wherever
    // the person was. A device on the far side may meet the resolution first.
    //
    // Dropping it is not an option — CLAUDE.md §1.1 — because the claim would
    // then arrive afterwards and sit ACTIVE forever on that phone, with
    // volunteers still being dispatched to someone already rescued. So it is
    // parked here and applied when the claim shows up (PERSON_A.md Wk3 D3).
    //
    // Persisted rather than held in memory for the same reason: a device that
    // restarts between the two arrivals must not forget.
    await db.execute('''
      CREATE TABLE pending_resolutions (
        sos_id              TEXT PRIMARY KEY,
        nonce               BLOB    NOT NULL,
        requester_pub_key   BLOB    NOT NULL,
        requester_sig       BLOB    NOT NULL,
        resolver_pub_key    BLOB    NOT NULL,   -- the counter-signing volunteer
        method              INTEGER NOT NULL,   -- ResolutionMethod
        clock_device_id     TEXT    NOT NULL,   -- resolvedAtLogical, see §4
        clock_counter       INTEGER NOT NULL
      );
    ''');

    // One row per (voucher, vouchee) pair. The primary key is the §2.2 rule
    // "a voucher speaks for a person once" expressed in the schema rather
    // than left to calling code: repeating a vouch must not let one voucher
    // consume its own cap twice, or count twice toward promotion.
    await db.execute('''
      CREATE TABLE vouches (
        voucher_pub_key BLOB    NOT NULL,
        vouchee_pub_key BLOB    NOT NULL,
        vouch_index     INTEGER NOT NULL,       -- self-asserted, diagnostic only
        vouch_cap       INTEGER NOT NULL,       -- carried inside the signed vouch
        voucher_sig     BLOB    NOT NULL,       -- envelope originSig, kept so the
                                                -- stored row stays independently
                                                -- verifiable without the envelope
        clock_device_id TEXT    NOT NULL,
        clock_counter   INTEGER NOT NULL,
        PRIMARY KEY (voucher_pub_key, vouchee_pub_key)
      );
    ''');

    await db.execute(
        'CREATE INDEX idx_vouches_vouchee ON vouches(vouchee_pub_key);');

    // Only the original voucher may revoke its own vouch, so the key is the
    // same pair. `clock_counter` is what "most recent valid revocation wins"
    // is measured on — a later re-vouch outranks an earlier revocation.
    await db.execute('''
      CREATE TABLE revocations (
        revoker_pub_key BLOB    NOT NULL,
        revoked_pub_key BLOB    NOT NULL,
        reason          INTEGER NOT NULL,       -- RevocationReason
        clock_device_id TEXT    NOT NULL,
        clock_counter   INTEGER NOT NULL,
        PRIMARY KEY (revoker_pub_key, revoked_pub_key)
      );
    ''');

    // Campaign-verified public keys — the roots the whole vouch web hangs
    // off. Empty in every build today: issuing and loading a campaign
    // credential is B's Phase 4 identity work, and until it exists no device
    // is campaign-verified and therefore no vouch can be accepted from
    // anyone. That is the correct failure direction (nobody is trusted by
    // accident) but it does mean vouching cannot be exercised end to end on
    // hardware yet. Flagged in PERSON_A.md.
    await db.execute('''
      CREATE TABLE trust_anchors (
        pub_key BLOB PRIMARY KEY,
        label   TEXT
      );
    ''');
  }

  /// Nonces already spent closing a rescue — CLAUDE.md §6.2's replay row.
  ///
  /// **Why a table and not a field on the claim.** A resolution can arrive
  /// for a claim this device does not hold (see `pending_resolutions` above),
  /// so there is no claim row to hang it off at the moment the decision has
  /// to be made. It also has to outlive the claim: the whole point is that a
  /// photographed QR presented hours later is refused, and by then the claim
  /// may well be ARCHIVED.
  ///
  /// Keyed on the pair, not the nonce alone. A nonce is 16 random bytes
  /// chosen by a stranger's phone; keying on it alone would let one device
  /// burn an id it does not own by asserting a collision.
  ///
  /// **Also not yet in CLAIM_SCHEMA.md §10** — same standing gap as the four
  /// tables above, same answer: §10 has no single owner, so recording it
  /// needs the three-person sync. Do not edit §10 alone.
  Future<void> _createConsumedNonceTable(Database db) async {
    await db.execute('''
      CREATE TABLE consumed_resolution_nonces (
        sos_id   TEXT NOT NULL,
        nonce    BLOB NOT NULL,
        PRIMARY KEY (sos_id, nonce)
      );
    ''');
  }

  /// Closes the store and drops the handle, so the next [database] call opens
  /// a fresh one.
  ///
  /// Dropping `_database` is the whole point. Without it this singleton goes
  /// on handing out a CLOSED handle for the rest of the process, and every
  /// later read fails with `database_closed` — including the read that puts
  /// SOS pins on the map. Closing must not be a one-way door (§1.1).
  ///
  /// Reads the field directly rather than going through [database]: the getter
  /// OPENS a database when none is held, so the old version could open one
  /// purely in order to close it.
  Future<void> close() async {
    final db = _database;
    if (db == null) return;
    await db.close();
    _database = null;
  }

  /// Test seam only — switches the store to an in-memory database and drops
  /// the open handle, so each test starts against a freshly created schema.
  ///
  /// In-memory rather than deleting the real file, for two reasons. It never
  /// touches a device's actual claim store, and `flutter test` runs files
  /// concurrently: on one shared file, one test's reset wipes another's data
  /// mid-run. Each test process gets its own in-memory database instead.
  ///
  /// Never call this from app code — §1.1 says an active SOS is never
  /// silently discarded, and this discards everything.
  /// Pass [path] when a test needs the store to SURVIVE a close — testing
  /// that claims are still there after an app restart, for instance. An
  /// in-memory database is discarded the moment it closes, so that test cannot
  /// be written against the default. Give it a unique temp file, never a
  /// shared one, or concurrent test files race for it again.
  Future<void> resetForTest({String? path}) async {
    _overridePath = path ?? inMemoryDatabasePath;
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
