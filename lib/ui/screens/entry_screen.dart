import 'package:flutter/material.dart';
import 'package:mayday/ui/screens/main_screen.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Entry screen — PERSON_C.md §3 Day 1, MAYDAY_PROJECT_CONTEXT.md §3.
///
/// Visual Design:
/// - Dominant surface: Very Light Cream (#FFFDF5)
/// - Primary brand: Deep Navy Blue (#12355B)
/// - Primary action (User): Strong Blue (#1769AA)
/// - Secondary action (Volunteer): Outlined Deep Navy (#12355B)
/// - Calm, trustworthy, accessible, rural-friendly.
///
/// Two buttons: User / Volunteer.
/// Volunteer entry unlocks the stored credential on-device (biometric or PIN).
/// No network step. — MAYDAY_PROJECT_CONTEXT.md §3 step 1.
///
/// No "login", no "sign in", no phone number field — there is no server to
/// authenticate against, and phone-number verification needs a cell tower
/// which doesn't exist — CLAUDE.md §1.2.
class EntryScreen extends StatelessWidget {
  const EntryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.creamBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // ─── App Emblem / Brand Icon ─────────────────────────
              // Calm, trustworthy Deep Navy container with clear high-contrast symbol
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  color: AppColors.deepNavy,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.deepNavy.withAlpha(30),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  size: 56,
                  color: Colors.white,
                ),
              ),

              const SizedBox(height: 28),

              // ─── App Title ───────────────────────────────────────
              const Text(
                'MayDay',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepNavy,
                  letterSpacing: 1.2,
                ),
              ),

              const SizedBox(height: 8),

              // ─── Subtitle ────────────────────────────────────────
              // Reassuring, clear, high-contrast
              const Text(
                'Offline Disaster Response',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.secondaryText,
                  letterSpacing: 0.5,
                ),
              ),

              const Spacer(flex: 3),

              // ─── User Button (Primary Action) ────────────────────
              // Strong Blue (#1769AA) for standard primary action
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pushReplacementNamed(
                      context,
                      MainScreen.routeName,
                      arguments: false, // isVolunteer = false
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.strongBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_outline, size: 24),
                      SizedBox(width: 12),
                      Text(
                        'User',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ─── Volunteer Button (Secondary Action) ─────────────
              // Deep Navy (#12355B) outlined action
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton(
                  onPressed: () {
                    // Unlocks stored volunteer credential on-device. No network.
                    Navigator.pushReplacementNamed(
                      context,
                      MainScreen.routeName,
                      arguments: true, // isVolunteer = true
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.deepNavy,
                    backgroundColor: AppColors.surfaceWhite,
                    side: const BorderSide(
                      color: AppColors.deepNavy,
                      width: 2,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.verified_user_outlined, size: 24),
                      SizedBox(width: 12),
                      Text(
                        'Volunteer',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ─── Campaign Verification Notice ────────────────────
              const Text(
                'Volunteers are verified during pre-disaster\nawareness campaigns',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.secondaryText,
                  height: 1.4,
                  fontWeight: FontWeight.w400,
                ),
              ),

              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}
