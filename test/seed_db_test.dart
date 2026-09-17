// test/seed_db_test.dart
//
// Covers `DebugClaimSeeder`, the debug-only path that fills the store with
// synthetic claims so the map can be exercised at realistic density.
//
// It is the one writer allowed to skip the §5 signature guard, because
// synthetic data has no origin device to sign it. That exemption is the thing
// worth testing: it must stay confined to debug builds and must stay visible
// in the data it writes.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/common/debug_claim_seeder.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/data/enums.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // Without this the seeder writes the real on-disk mayday.db. `flutter test`
  // runs files concurrently, so two seeding tests then race for the same file
  // and one dies with SQLITE_BUSY ("database is locked") — which is exactly
  // what happened before, and is what resetForTest()'s own doc comment warns
  // about. It also stopped rows accumulating across runs, which made the old
  // row counts meaningless.
  setUp(() async {
    await DatabaseHelper.instance.resetForTest();
  });

  test('seeds the requested number of claims into a fresh store', () async {
    final seeded = await DebugClaimSeeder.seedSyntheticClaims(count: 120);
    expect(seeded, 120);

    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('claims');

    // Fewer ROWS than claims seeded is correct, not a bug. Hazard and resource
    // ids are hash(type + geohash_bucket), so synthetic claims landing in one
    // bucket merge onto each other by design. SOS ids never do (§2.1).
    expect(rows, isNotEmpty);
    expect(rows.length, lessThanOrEqualTo(120));
  });

  test('seeded claims carry the debug unsigned marker, not a forged signature',
      () async {
    await DebugClaimSeeder.seedSyntheticClaims(count: 40);

    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('claims');

    // The seeder must leave synthetic rows obviously unsigned. Padding them to
    // 64 plausible-looking bytes would let debug data impersonate a real
    // signed claim, and §5's guard would then wave it through everywhere.
    for (final row in rows) {
      expect(
        (row['origin_signature'] as List).length,
        0,
        reason: 'synthetic claim ${row['id']} should be visibly unsigned',
      );
    }
  });

  test('seeds resource claims, which the map layer toggle needs', () async {
    await DebugClaimSeeder.seedSyntheticClaims(count: 120);

    final db = await DatabaseHelper.instance.database;
    final resources = await db.query(
      'claims',
      where: 'type = ?',
      whereArgs: [ClaimType.resource.index],
    );

    expect(resources, isNotEmpty);
  });
}
