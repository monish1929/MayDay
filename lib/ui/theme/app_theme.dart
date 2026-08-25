import 'package:flutter/material.dart';

/// MayDay UI Theme & Visual Design System.
///
/// Design Direction:
/// - Calm, Trustworthy, Rural-friendly, High-contrast, Emergency-ready, Accessible.
/// - The default interface feels calm and trustworthy (Navy + Cream + Blue).
/// - Emergency colors (Dark Red) appear only when necessary for life-critical states.
///
/// Final Visual Identity:
/// - NAVY (#12355B)   = TRUST
/// - CREAM (#FFFDF5)  = CALM
/// - BLUE (#1769AA)   = ACTION
/// - AMBER (#F2B134)  = WARNING
/// - GREEN (#18794E)  = SAFE
/// - RED (#B42318)    = EMERGENCY
class AppColors {
  // ─── Primary Color Palette ──────────────────────────────────────
  /// Very Light Cream — Dominant surface & page background
  static const Color creamBackground = Color(0xFFFFFDF5);

  /// Deep Navy Blue — Main header, navigation, primary structural elements
  static const Color deepNavy = Color(0xFF12355B);

  /// Strong Blue — Standard primary buttons, normal actions, links, interactive
  static const Color strongBlue = Color(0xFF1769AA);

  /// Dark Red — Life-critical states, SOS, immediate danger (used intentionally)
  static const Color darkRed = Color(0xFFB42318);

  /// Amber Yellow — Warnings, caution, hazard backgrounds & accent borders
  static const Color amberYellow = Color(0xFFF2B134);

  /// Amber Dark — Deliberate WCAG AA high-contrast variant (>4.5:1 on light cream/white surfaces)
  /// specifically for text labels and icon strokes, where #F2B134 would lack sufficient readability.
  static const Color amberDark = Color(0xFFB45309);

  /// Dark Green — Safe states, available resources, ground confirmed
  static const Color darkGreen = Color(0xFF18794E);

  /// Primary Text — Headings, main text, important labels
  static const Color primaryText = Color(0xFF1F2933);

  /// Secondary Text — Supporting info, metadata, descriptions
  static const Color secondaryText = Color(0xFF52606D);

  // ─── Surface & Border Colors ────────────────────────────────────
  /// Pure white surface for cards & floating action containers
  static const Color surfaceWhite = Color(0xFFFFFFFF);

  /// Subtle clean border for cards, inputs, and dividers
  static const Color borderSubtle = Color(0xFFD8E2EC);

  /// Border for higher emphasis elements
  static const Color borderMedium = Color(0xFFCBD2D9);

  // ─── Chip / Badge Tints ─────────────────────────────────────────
  static const Color redLight = Color(0xFFFEE2E2);
  static const Color amberLight = Color(0xFFFEF3C7);
  static const Color greenLight = Color(0xFFE6F4EA);
  static const Color blueLight = Color(0xFFEBF8FF);
  static const Color grayLight = Color(0xFFF0F4F8);
}

/// Global ThemeData configured for MayDay.
class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.creamBackground,
      primaryColor: AppColors.deepNavy,
      colorScheme: const ColorScheme.light(
        primary: AppColors.deepNavy,
        secondary: AppColors.strongBlue,
        surface: AppColors.surfaceWhite,
        error: AppColors.darkRed,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: AppColors.primaryText,
        onError: Colors.white,
      ),
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.deepNavy,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.strongBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.deepNavy,
          side: const BorderSide(color: AppColors.deepNavy, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surfaceWhite,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
    );
  }
}
