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
