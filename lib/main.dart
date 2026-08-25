import 'package:flutter/material.dart';
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
  runApp(const MayDayApp());
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
