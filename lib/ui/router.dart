import 'package:flutter/material.dart';
import 'package:mayday/ui/screens/entry_screen.dart';
import 'package:mayday/ui/screens/main_screen.dart';
import 'package:mayday/ui/screens/volunteer_ops_screen.dart';

/// App route definitions — PERSON_C.md §3 Day 1.
///
/// Routes:
///   /          → EntryScreen (User / Volunteer choice)
///   /main      → MainScreen (map + bottom sheet + layer toggle)
///   /volunteer-ops → VolunteerOpsScreen (rescue queue, reports, resources)
class AppRouter {
  static const String entry = '/';
  static const String main = MainScreen.routeName;
  static const String volunteerOps = VolunteerOpsScreen.routeName;

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case entry:
        return MaterialPageRoute(
          builder: (_) => const EntryScreen(),
          settings: settings,
        );

      case main:
        final isVolunteer = settings.arguments as bool? ?? false;
        return MaterialPageRoute(
          builder: (_) => MainScreen(isVolunteer: isVolunteer),
          settings: settings,
        );

      case volunteerOps:
        return MaterialPageRoute(
          builder: (_) => const VolunteerOpsScreen(),
          settings: settings,
        );

      default:
        return MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: const Color(0xFFFFFDF5),
            body: Center(
              child: Text(
                'Route not found: ${settings.name}',
                style: const TextStyle(color: Color(0xFF52606D)),
              ),
            ),
          ),
          settings: settings,
        );
    }
  }
}
