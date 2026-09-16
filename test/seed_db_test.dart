import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mayday/common/debug_claim_seeder.dart';
import 'package:mayday/data/database/database_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('Seed claims bypasses signature guard', () async {
    final count = await DebugClaimSeeder.seedSyntheticClaims(count: 120);
    print('Seeded count returned: $count');
    
    final db = await DatabaseHelper.instance.database;
    final List<Map<String, dynamic>> results = await db.query('claims');
    print('Claims actually in DB: ${results.length}');
  });
}
