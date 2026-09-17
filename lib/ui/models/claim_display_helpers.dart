import 'package:flutter/material.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Centralized display formatting, styling, and sorting helpers for claims.
///
/// Invariants:
/// - Relative time only — never a precise wall-clock timestamp (CLAIM_SCHEMA.md §4).
/// - Aging SOS escalation — 1hr/3hr/6hr+ thresholds (CLAUDE.md §2.3, CLAIM_SCHEMA.md §7).
/// - Trust tier appearance tokens (CLAIM_SCHEMA.md §3).
/// - Dispatch priority appearance tokens (CLAIM_SCHEMA.md §3.4).
/// - Availability is computed, never stored (CLAIM_SCHEMA.md §8.1).
abstract final class ClaimDisplayHelpers {
  /// Whether an SOS/SOS_PROXY claim has aged past the urgency threshold.
  static bool isAgingSos(Claim claim) {
    if (!(claim.type == ClaimType.sos || claim.type == ClaimType.sosProxy)) {
      return false;
    }
    if (claim.status != ClaimStatus.active) return false;
    // In Week 2, time is driven by LogicalClock / mesh time gossip (CLAIM_SCHEMA.md §4).
    final counter = claim.createdAtLogical?.counter ?? claim.logicalClock.counter;
    return counter > 10;
  }

  /// Urgency tier for aging SOS:
  /// 0 = not aging
  /// 1 = aging tier 1
  /// 2 = aging tier 2
  /// 3 = aging tier 3 (highest urgency)
  static int agingTier(Claim claim) {
    if (!isAgingSos(claim)) return 0;
    final counter = claim.createdAtLogical?.counter ?? claim.logicalClock.counter;
    if (counter > 30) return 3;
    if (counter > 20) return 2;
    return 1;
  }

  /// Compact aging label for badges (e.g. "#15").
  static String agingBadgeLabel(LogicalClock? clock) {
    final counter = clock?.counter ?? 0;
    return '#$counter';
  }

  /// Bucketed relative-time string — CLAIM_SCHEMA.md §4.
  /// Never a precise timestamp. Uses logical clock until MeshTimeGossip estimate in Day 3.
  static String relativeTimeLabel(LogicalClock? clock) {
    if (clock == null) return 'Recently';
    return 'Clock #${clock.counter}';
  }

  /// Human-readable headcount string (e.g., "2-5 people").
  static String headcountLabel(HeadcountBucket bucket) => switch (bucket) {
        HeadcountBucket.twoToFive => '2-5 people',
        HeadcountBucket.sixToFifteen => '6-15 people',
        HeadcountBucket.fifteenPlus => '15+ people',
      };

  /// Short headcount badge text (e.g., "2-5").
  static String headcountShort(HeadcountBucket bucket) => switch (bucket) {
        HeadcountBucket.twoToFive => '2-5',
        HeadcountBucket.sixToFifteen => '6-15',
        HeadcountBucket.fifteenPlus => '15+',
      };

  /// Visual styling configuration for trust tiers — CLAIM_SCHEMA.md §3.
  static ({String label, Color fg, Color bg, Color border}) trustConfig(
    ClaimTrust trust,
  ) =>
      switch (trust) {
        ClaimTrust.unconfirmed => (
            label: 'UNCONFIRMED',
            fg: AppColors.secondaryText,
            bg: AppColors.grayLight,
            border: AppColors.borderSubtle,
          ),
        ClaimTrust.corroborated => (
            label: 'CORROBORATED',
            fg: AppColors.strongBlue,
            bg: AppColors.blueLight,
            border: const Color(0xFFBEE3F8),
          ),
        ClaimTrust.groundConfirmed => (
            label: 'GROUND CONFIRMED',
            fg: AppColors.darkGreen,
            bg: AppColors.greenLight,
            border: const Color(0xFFA7F3D0),
          ),
      };

  /// Visual styling configuration for dispatch priority — CLAIM_SCHEMA.md §3.4.
  static ({String label, Color fg, Color bg, Color border}) priorityConfig(
    DispatchPriority priority,
  ) =>
      switch (priority) {
        DispatchPriority.low => (
            label: 'LOW',
            fg: AppColors.secondaryText,
            bg: AppColors.grayLight,
            border: AppColors.borderSubtle,
          ),
        DispatchPriority.seenByVolunteer => (
            label: 'SEEN',
            fg: AppColors.amberDark,
            bg: AppColors.amberLight,
            border: const Color(0xFFFDE68A),
          ),
        DispatchPriority.enRoute => (
            label: 'EN ROUTE',
            fg: AppColors.strongBlue,
            bg: AppColors.blueLight,
            border: const Color(0xFF90CDF4),
          ),
      };

  /// Type brand color.
  static Color colorForType(ClaimType type) => switch (type) {
        ClaimType.sos => AppColors.darkRed,
        ClaimType.sosProxy => AppColors.darkRed,
        ClaimType.hazardReport => AppColors.amberDark,
        ClaimType.resource => AppColors.darkGreen,
      };

  /// Type icon.
  static IconData iconForType(ClaimType type) => switch (type) {
        ClaimType.sos => Icons.sos_rounded,
        ClaimType.sosProxy => Icons.person_pin_circle_outlined,
        ClaimType.hazardReport => Icons.report_problem_outlined,
        ClaimType.resource => Icons.inventory_2_outlined,
      };

  /// Type human-readable title.
  static String labelForType(ClaimType type) => switch (type) {
        ClaimType.sos => 'SOS Rescue',
        ClaimType.sosProxy => 'Proxy SOS',
        ClaimType.hazardReport => 'Hazard Report',
        ClaimType.resource => 'Resource',
      };

  /// Icon per hazard type.
  static IconData iconForHazard(HazardType type) => switch (type) {
        HazardType.flood => Icons.water_drop_outlined,
        HazardType.roadBlock => Icons.block_outlined,
        HazardType.structuralDamage => Icons.domain_disabled_outlined,
        HazardType.other => Icons.warning_amber_rounded,
      };

  /// Icon per resource category.
  static IconData iconForResource(ResourceCategory cat) => switch (cat) {
        ResourceCategory.foodWater => Icons.restaurant,
        ResourceCategory.shelter => Icons.home_outlined,
        ResourceCategory.medical => Icons.medical_services_outlined,
        ResourceCategory.equipment => Icons.build_outlined,
      };

  /// Category human-readable title.
  static String labelForResourceCategory(ResourceCategory cat) => switch (cat) {
        ResourceCategory.foodWater => 'Food & Water',
        ResourceCategory.shelter => 'Shelter',
        ResourceCategory.medical => 'Medical',
        ResourceCategory.equipment => 'Equipment',
      };

  // ─── Sorting Helpers (PERSON_C.md §3 Day 5) ──────────────────────────

  /// Sorts rescue queue by dispatchPriority first (enRoute > seenByVolunteer > low),
  /// then by claimTrust (groundConfirmed > corroborated > unconfirmed),
  /// then by causal logical clock ordering.
  static int compareRescueClaims(Claim a, Claim b) {
    final pA = _priorityRank(a.dispatchPriority);
    final pB = _priorityRank(b.dispatchPriority);
    if (pA != pB) return pB.compareTo(pA); // higher priority first

    final tA = _trustRank(a.claimTrust);
    final tB = _trustRank(b.claimTrust);
    if (tA != tB) return tB.compareTo(tA); // higher trust first

    return a.logicalClock.compareTo(b.logicalClock); // logical clock ordering
  }

  /// Sorts hazard reports by confirmation count descending (most confirmed first).
  static int compareHazardClaims(Claim a, Claim b) {
    final countA = a.payload is HazardReportPayload
        ? (a.payload as HazardReportPayload).confirmationCount
        : 0;
    final countB = b.payload is HazardReportPayload
        ? (b.payload as HazardReportPayload).confirmationCount
        : 0;
    if (countA != countB) return countB.compareTo(countA);

    final tA = _trustRank(a.claimTrust);
    final tB = _trustRank(b.claimTrust);
    if (tA != tB) return tB.compareTo(tA);

    return a.logicalClock.compareTo(b.logicalClock);
  }

  static int _priorityRank(DispatchPriority p) => switch (p) {
        DispatchPriority.enRoute => 2,
        DispatchPriority.seenByVolunteer => 1,
        DispatchPriority.low => 0,
      };

  static int _trustRank(ClaimTrust t) => switch (t) {
        ClaimTrust.groundConfirmed => 2,
        ClaimTrust.corroborated => 1,
        ClaimTrust.unconfirmed => 0,
      };
}
