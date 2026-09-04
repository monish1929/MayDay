import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mayday/ui/map/claim_detail_sheet.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/screens/qr_scanner_screen.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Volunteer ops screen — PERSON_C.md §3 Day 5.
///
/// Dedicated triage and coordination screen for verified volunteer nodes.
/// Three core views in a single screen:
/// 1. Rescue Queue: active SOS / Proxy SOS sorted by dispatchPriority then claimTrust.
/// 2. Report Review: active hazard reports sorted by confirmation count descending.
/// 3. Resource Coordination: active resources with category filtering and real availability.
///
/// Header includes direct access to the QR Scanner skeleton (Phase 3 resolution scaffold).
class VolunteerOpsScreen extends StatefulWidget {
  static const routeName = '/volunteer-ops';

  const VolunteerOpsScreen({super.key});

  @override
  State<VolunteerOpsScreen> createState() => _VolunteerOpsScreenState();
}

class _VolunteerOpsScreenState extends State<VolunteerOpsScreen> {
  // Selected category filter for the Resource coordination tab (null = All)
  ResourceCategory? _selectedResourceCategory;
  StreamSubscription<List<Claim>>? _claimsSubscription;
  List<Claim> _allClaims = [];

  @override
  void initState() {
    super.initState();
    _subscribeToClaims();
  }

  void _subscribeToClaims() {
    _claimsSubscription = ClaimRepository().watchActiveClaims().listen(
      (claims) {
        if (!mounted) return;
        setState(() {
          _allClaims = claims;
        });
      },
      onError: (e) {
        debugPrint('[VolunteerOpsScreen] Error from watchActiveClaims: $e');
      },
    );
  }

  @override
  void dispose() {
    _claimsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allClaims = _allClaims;

    // ─── 1. Rescue Queue (active SOS / SOS_PROXY) ───────────────────
    final rescueClaims = allClaims
        .where((c) =>
            (c.type == ClaimType.sos || c.type == ClaimType.sosProxy) &&
            c.status == ClaimStatus.active)
        .toList()
      ..sort(ClaimDisplayHelpers.compareRescueClaims);

    // ─── 2. Hazard Reports (active HAZARD_REPORT) ───────────────────
    final hazardClaims = allClaims
        .where((c) =>
            c.type == ClaimType.hazardReport && c.status == ClaimStatus.active)
        .toList()
      ..sort(ClaimDisplayHelpers.compareHazardClaims);

    // ─── 3. Resources (active RESOURCE) ─────────────────────────────
    final resourceClaims = allClaims
        .where((c) =>
            c.type == ClaimType.resource &&
            c.status == ClaimStatus.active &&
            (_selectedResourceCategory == null ||
                (c.payload as ResourcePayload).category ==
                    _selectedResourceCategory))
        .toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: AppColors.creamBackground,
        appBar: AppBar(
          backgroundColor: AppColors.deepNavy,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Row(
            children: [
              Icon(Icons.assignment_outlined, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text(
                'Volunteer Ops',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          actions: [
            // QR Scanner Screen Entry Action
            IconButton(
              icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
              tooltip: 'Scan QR Verification',
              onPressed: () {
                Navigator.pushNamed(context, QRScannerScreen.routeName);
              },
            ),
          ],
          bottom: TabBar(
            indicatorColor: AppColors.amberYellow,
            indicatorWeight: 3,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            tabs: [
              Tab(
                icon: const Icon(Icons.sos_rounded, size: 18),
                text: 'Rescue (${rescueClaims.length})',
              ),
              Tab(
                icon: const Icon(Icons.report_problem_outlined, size: 18),
                text: 'Reports (${hazardClaims.length})',
              ),
              Tab(
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                text: 'Resources (${resourceClaims.length})',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // ─── Rescue Queue ───────────────────────────────────────
            _buildRescueQueueTab(context, rescueClaims),

            // ─── Report Review ──────────────────────────────────────
            _buildReportReviewTab(context, hazardClaims),

            // ─── Resource Coordination ──────────────────────────────
            _buildResourceCoordinationTab(context, resourceClaims),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  // 1. RESCUE QUEUE TAB
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildRescueQueueTab(
    BuildContext context,
    List<Claim> claims,
  ) {
    if (claims.isEmpty) {
      return _buildEmptyState(
        icon: Icons.check_circle_outline,
        title: 'Rescue Queue Clear',
        subtitle: 'No active SOS or Proxy SOS claims found in the mesh.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: claims.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final claim = claims[index];
        final isProxy = claim.type == ClaimType.sosProxy;
        final isAging = ClaimDisplayHelpers.isAgingSos(claim);
        final trust = ClaimDisplayHelpers.trustConfig(claim.claimTrust);
        final priority = ClaimDisplayHelpers.priorityConfig(claim.dispatchPriority);
        final relTime = ClaimDisplayHelpers.relativeTimeLabel(claim.createdAtLogical);

        return InkWell(
          onTap: () => ClaimDetailSheet.show(context, claim),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isAging
                    ? AppColors.darkRed
                    : (isProxy ? AppColors.amberDark.withAlpha(150) : AppColors.borderSubtle),
                width: isAging ? 2.0 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: Type title + Trust & Priority badges
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.redLight,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        isProxy ? Icons.person_pin_circle_outlined : Icons.sos_rounded,
                        color: AppColors.darkRed,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isProxy ? 'Proxy SOS' : 'Self-Raised SOS',
                            style: const TextStyle(
                              color: AppColors.primaryText,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            'ID: ${claim.id}',
                            style: const TextStyle(
                              color: AppColors.secondaryText,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildBadge(trust.label, trust.fg, trust.bg, trust.border),
                    const SizedBox(width: 6),
                    _buildBadge(priority.label, priority.fg, priority.bg, priority.border),
                  ],
                ),

                const SizedBox(height: 12),

                // Details: Headcount & Coordinates
                _buildRescueDetailsRow(claim),

                // Aging Urgency Notice Banner
                if (isAging) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.redLight,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.darkRed.withAlpha(120)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.darkRed),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Aging SOS: Unresolved for $relTime — escalated response priority',
                            style: const TextStyle(
                              color: AppColors.darkRed,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 10),
                const Divider(height: 1, color: AppColors.borderSubtle),
                const SizedBox(height: 8),

                // Footer: relative time & inspect action hint
                Row(
                  children: [
                    const Icon(Icons.access_time, size: 13, color: AppColors.secondaryText),
                    const SizedBox(width: 4),
                    Text(
                      relTime,
                      style: const TextStyle(
                        color: AppColors.secondaryText,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'Tap to triage',
                      style: TextStyle(
                        color: AppColors.strongBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 16, color: AppColors.strongBlue),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRescueDetailsRow(Claim claim) {
    if (claim.payload is SosPayload) {
      final p = claim.payload as SosPayload;
      return Row(
        children: [
          const Icon(Icons.people_outline, size: 16, color: AppColors.secondaryText),
          const SizedBox(width: 6),
          Text(
            p.headcount != null
                ? ClaimDisplayHelpers.headcountLabel(p.headcount!)
                : 'Individual (Single person)',
            style: const TextStyle(
              color: AppColors.primaryText,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          const Icon(Icons.location_on_outlined, size: 14, color: AppColors.secondaryText),
          const SizedBox(width: 4),
          Text(
            '${p.location.lat.toStringAsFixed(4)}, ${p.location.lon.toStringAsFixed(4)}',
            style: const TextStyle(
              color: AppColors.secondaryText,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      );
    } else if (claim.payload is SosProxyPayload) {
      final p = claim.payload as SosProxyPayload;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.people_outline, size: 16, color: AppColors.secondaryText),
              const SizedBox(width: 6),
              Text(
                p.headcount != null
                    ? 'Headcount: ${ClaimDisplayHelpers.headcountLabel(p.headcount!)}'
                    : 'Proxy (Reported for neighbour)',
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const Icon(Icons.location_on_outlined, size: 14, color: AppColors.secondaryText),
              const SizedBox(width: 4),
              Text(
                '${p.location.lat.toStringAsFixed(4)}, ${p.location.lon.toStringAsFixed(4)}',
                style: const TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          if (p.proxyNote != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.creamBackground,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Text(
                '"${p.proxyNote}"',
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      );
    }
    return const SizedBox.shrink();
  }

  // ═══════════════════════════════════════════════════════════════════
  // 2. REPORT REVIEW TAB
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildReportReviewTab(
    BuildContext context,
    List<Claim> claims,
  ) {
    if (claims.isEmpty) {
      return _buildEmptyState(
        icon: Icons.check_circle_outline,
        title: 'No Hazard Reports',
        subtitle: 'No active hazard reports currently need review.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: claims.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final claim = claims[index];
        final payload = claim.payload as HazardReportPayload;
        final trust = ClaimDisplayHelpers.trustConfig(claim.claimTrust);
        final priority = ClaimDisplayHelpers.priorityConfig(claim.dispatchPriority);
        final relTime = ClaimDisplayHelpers.relativeTimeLabel(claim.createdAtLogical);

        return InkWell(
          onTap: () => ClaimDetailSheet.show(context, claim),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: Hazard kind + Confirm count + Badges
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.amberLight,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        ClaimDisplayHelpers.iconForHazard(payload.hazardType),
                        color: AppColors.amberDark,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            payload.hazardType.name.toUpperCase(),
                            style: const TextStyle(
                              color: AppColors.amberDark,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            '${payload.confirmationCount} Independent Reports Merged',
                            style: const TextStyle(
                              color: AppColors.primaryText,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildBadge(trust.label, trust.fg, trust.bg, trust.border),
                    const SizedBox(width: 6),
                    _buildBadge(priority.label, priority.fg, priority.bg, priority.border),
                  ],
                ),

                const SizedBox(height: 10),

                // Location coordinates
                Row(
                  children: [
                    const Icon(Icons.location_on_outlined, size: 14, color: AppColors.secondaryText),
                    const SizedBox(width: 4),
                    Text(
                      '${payload.location.lat.toStringAsFixed(4)}, ${payload.location.lon.toStringAsFixed(4)}',
                      style: const TextStyle(
                        color: AppColors.secondaryText,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Hops left: ${claim.hopLimit}',
                      style: const TextStyle(
                        color: AppColors.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),

                if (payload.note != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.creamBackground,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Text(
                      '"${payload.note}"',
                      style: const TextStyle(
                        color: AppColors.primaryText,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 10),
                const Divider(height: 1, color: AppColors.borderSubtle),
                const SizedBox(height: 8),

                // Footer: relative time & inspect action hint
                Row(
                  children: [
                    const Icon(Icons.access_time, size: 13, color: AppColors.secondaryText),
                    const SizedBox(width: 4),
                    Text(
                      relTime,
                      style: const TextStyle(
                        color: AppColors.secondaryText,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'Review report',
                      style: TextStyle(
                        color: AppColors.amberDark,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 16, color: AppColors.amberDark),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  // 3. RESOURCE COORDINATION TAB
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildResourceCoordinationTab(
    BuildContext context,
    List<Claim> claims,
  ) {
    return Column(
      children: [
        // Category Filter Chips Header
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: AppColors.surfaceWhite,
            border: Border(
              bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildCategoryFilterChip('All', null),
                const SizedBox(width: 8),
                _buildCategoryFilterChip(
                  'Food & Water',
                  ResourceCategory.foodWater,
                  icon: Icons.restaurant,
                ),
                const SizedBox(width: 8),
                _buildCategoryFilterChip(
                  'Shelter',
                  ResourceCategory.shelter,
                  icon: Icons.home_outlined,
                ),
                const SizedBox(width: 8),
                _buildCategoryFilterChip(
                  'Medical',
                  ResourceCategory.medical,
                  icon: Icons.medical_services_outlined,
                ),
                const SizedBox(width: 8),
                _buildCategoryFilterChip(
                  'Equipment',
                  ResourceCategory.equipment,
                  icon: Icons.build_outlined,
                ),
              ],
            ),
          ),
        ),

        // Resource list
        Expanded(
          child: claims.isEmpty
              ? _buildEmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'No Resources Found',
                  subtitle: 'No active resource claims in the selected category.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: claims.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final claim = claims[index];
                    final payload = claim.payload as ResourcePayload;
                    final trust = ClaimDisplayHelpers.trustConfig(claim.claimTrust);
                    final priority = ClaimDisplayHelpers.priorityConfig(claim.dispatchPriority);
                    final relTime = ClaimDisplayHelpers.relativeTimeLabel(claim.createdAtLogical);

                    return InkWell(
                      onTap: () => ClaimDetailSheet.show(context, claim),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceWhite,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.borderSubtle, width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(15),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header: Category title + Available Count + Badges
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppColors.greenLight,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    ClaimDisplayHelpers.iconForResource(payload.category),
                                    color: AppColors.darkGreen,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        ClaimDisplayHelpers.labelForResourceCategory(payload.category),
                                        style: const TextStyle(
                                          color: AppColors.darkGreen,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        '${payload.available} Available Units',
                                        style: const TextStyle(
                                          color: AppColors.primaryText,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                _buildBadge(trust.label, trust.fg, trust.bg, trust.border),
                                const SizedBox(width: 6),
                                _buildBadge(priority.label, priority.fg, priority.bg, priority.border),
                              ],
                            ),

                            const SizedBox(height: 12),

                            // Pledged vs Claimed breakdown (availability is computed: max(0, pledged - claimed))
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: AppColors.creamBackground,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppColors.borderSubtle),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  Column(
                                    children: [
                                      const Text(
                                        'PLEDGED',
                                        style: TextStyle(
                                          color: AppColors.secondaryText,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${payload.pledgedCount}',
                                        style: const TextStyle(
                                          color: AppColors.primaryText,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    width: 1,
                                    height: 24,
                                    color: AppColors.borderMedium,
                                  ),
                                  Column(
                                    children: [
                                      const Text(
                                        'CLAIMED',
                                        style: TextStyle(
                                          color: AppColors.secondaryText,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${payload.claimedReports}',
                                        style: const TextStyle(
                                          color: AppColors.amberDark,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    width: 1,
                                    height: 24,
                                    color: AppColors.borderMedium,
                                  ),
                                  Column(
                                    children: [
                                      const Text(
                                        'NET AVAILABLE',
                                        style: TextStyle(
                                          color: AppColors.secondaryText,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${payload.available}',
                                        style: const TextStyle(
                                          color: AppColors.darkGreen,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 10),

                            // Location coordinates
                            Row(
                              children: [
                                const Icon(Icons.location_on_outlined, size: 14, color: AppColors.secondaryText),
                                const SizedBox(width: 4),
                                Text(
                                  '${payload.location.lat.toStringAsFixed(4)}, ${payload.location.lon.toStringAsFixed(4)}',
                                  style: const TextStyle(
                                    color: AppColors.secondaryText,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  'Hops left: ${claim.hopLimit}',
                                  style: const TextStyle(
                                    color: AppColors.secondaryText,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 10),
                            const Divider(height: 1, color: AppColors.borderSubtle),
                            const SizedBox(height: 8),

                            // Footer: relative time & inspect action hint
                            Row(
                              children: [
                                const Icon(Icons.access_time, size: 13, color: AppColors.secondaryText),
                                const SizedBox(width: 4),
                                Text(
                                  relTime,
                                  style: const TextStyle(
                                    color: AppColors.secondaryText,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                                const Spacer(),
                                const Text(
                                  'Manage supply',
                                  style: TextStyle(
                                    color: AppColors.darkGreen,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const Icon(Icons.chevron_right, size: 16, color: AppColors.darkGreen),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  // SHARED WIDGET HELPERS
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildCategoryFilterChip(
    String label,
    ResourceCategory? category, {
    IconData? icon,
  }) {
    final isSelected = _selectedResourceCategory == category;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedResourceCategory = category;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.darkGreen : AppColors.creamBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.darkGreen : AppColors.borderSubtle,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: isSelected ? Colors.white : AppColors.darkGreen,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? Colors.white : AppColors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(String label, Color fg, Color bg, Color border) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surfaceWhite,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.borderSubtle, width: 1.5),
              ),
              child: Icon(icon, size: 42, color: AppColors.secondaryText.withAlpha(140)),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.primaryText,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
