import 'package:flutter/material.dart';
import 'package:mayday/mesh/mesh_bootstrap.dart';
import 'package:mayday/ui/router.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// MayDay — Offline Disaster Response System.
///
/// Pure offline. No server, no internet, no cell network — not as a fallback,
/// not "eventually," not at all. — CLAUDE.md §1.
///
/// Nothing in this app implies connectivity. No "syncing…", no "offline mode"
/// banner, no retry spinner, no cloud icons. The app has one mode.
/// — PERSON_C.md §6.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MayDayApp());

  // The mesh comes up alongside the UI, not before it. Starting the radio
  // involves a permission prompt and a GATT server, and neither is a reason to
  // hold back the map: a phone with Bluetooth off, or a user who declines the
  // prompt, still gets a working offline map and its own local claims.
  // Deliberately not awaited — nothing on this path may delay first paint.
  MeshBootstrap.start();
}

class MayDayApp extends StatelessWidget {
  const MayDayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MayDay',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      initialRoute: AppRouter.entry,
      onGenerateRoute: AppRouter.generateRoute,
    );
  }
}
