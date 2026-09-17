// test/run_seeder.dart
//
// A manual script, not a test — run it with `dart run test/run_seeder.dart`
// when you want a populated store to look at by hand. `flutter test` ignores
// it, because the runner only collects `*_test.dart`.
//
// The assertions about seeding live in `seed_db_test.dart`. This exists for
// the case that file cannot serve: seeing the data on a real device.
//
// ignore_for_file: avoid_print — stdout is this script's entire interface.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/common/debug_claim_seeder.dart';
import 'package:mayday/data/database/database_helper.dart';

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  print('Starting seeder test...');
  final count = await DebugClaimSeeder.seedSyntheticClaims(count: 120);
  print('Seeded count returned: $count');
  
  final db = await DatabaseHelper.instance.database;
  final List<Map<String, dynamic>> results = await db.query('claims');
  print('Claims actually in DB: ${results.length}');
  
  int resourceCount = 0;
  for (var row in results) {
    if (row['type'] == 3) { // Resource type
      resourceCount++;
    }
  }
  print('Resource claims in DB: $resourceCount');
}
