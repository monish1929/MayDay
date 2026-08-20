import 'package:flutter/material.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Volunteer ops screen — PERSON_C.md §3 Day 5.
///
/// Extra screen visible only to Volunteer/NGO-Authority nodes.
/// Three sections: rescue queue, report review, resource coordination.
///
/// Visual Design:
/// - Header: Deep Navy Blue (#12355B)
/// - Background: Very Light Cream (#FFFDF5)
/// - Cards: Flat White (#FFFFFF) with clean borders (#D8E2EC)
/// - High contrast, accessible typography (#1F2933, #52606D)
/// - Trust Tiers & Priority Badges mapped cleanly to the color hierarchy.
///
/// Sorted by dispatchPriority then claimTrust — PERSON_C.md §3 Day 5.
class VolunteerOpsScreen extends StatelessWidget {
  static const routeName = '/volunteer-ops';

  const VolunteerOpsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Get mock claims for display
    final claims = MockData.generateMockClaims();
    final sosClaims = claims
        .where((c) =>
            c.type == ClaimType.sos || c.type == ClaimType.sosProxy)
        .toList();
    final hazardClaims = claims
        .where((c) => c.type == ClaimType.hazardReport)
        .toList();
    final resourceClaims = claims
        .where((c) => c.type == ClaimType.resource)
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
              Icon(Icons.verified_user_outlined, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text(
                'Volunteer Ops',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          bottom: TabBar(
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
            tabs: const [
              Tab(icon: Icon(Icons.sos_rounded, size: 18), text: 'Rescue'),
              Tab(
                icon: Icon(Icons.report_problem_outlined, size: 18),
                text: 'Reports',
              ),
              Tab(
                icon: Icon(Icons.inventory_2_outlined, size: 18),
                text: 'Resources',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // ─── Rescue queue ──────────────────────────────────────
            _buildClaimList(
              claims: sosClaims,
              emptyMessage: 'No active rescue requests',
              emptyIcon: Icons.check_circle_outline,
            ),

            // ─── Report review ─────────────────────────────────────
            _buildClaimList(
              claims: hazardClaims,
              emptyMessage: 'No hazard reports to review',
              emptyIcon: Icons.landscape_outlined,
            ),

            // ─── Resource coordination ─────────────────────────────
            _buildClaimList(
              claims: resourceClaims,
              emptyMessage: 'No resources pinned',
              emptyIcon: Icons.inventory_2_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClaimList({
    required List<MockClaim> claims,
    required String emptyMessage,
    required IconData emptyIcon,
  }) {
    if (claims.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(emptyIcon, size: 48, color: AppColors.secondaryText.withAlpha(100)),
            const SizedBox(height: 12),
            Text(
              emptyMessage,
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: claims.length,
      itemBuilder: (context, index) {
        final claim = claims[index];
        return _ClaimCard(claim: claim);
      },
    );
  }
}

class _ClaimCard extends StatelessWidget {
  final MockClaim claim;

  const _ClaimCard({required this.claim});

  @override
  Widget build(BuildContext context) {
    final typeColor = _colorForType(claim.type);
    final trustConfig = _trustConfig(claim.claimTrust);
    final priorityConfig = _priorityConfig(claim.dispatchPriority);

    return Card(
      color: AppColors.surfaceWhite,
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.borderSubtle, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row — type + trust + priority
            Row(
              children: [
                Icon(_iconForType(claim.type), color: typeColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  _labelForType(claim.type),
                  style: TextStyle(
                    color: typeColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                _buildBadge(trustConfig.label, trustConfig.fg, trustConfig.bg, trustConfig.border),
                const SizedBox(width: 6),
                _buildBadge(priorityConfig.label, priorityConfig.fg, priorityConfig.bg, priorityConfig.border),
              ],
            ),

            const SizedBox(height: 10),

            // Claim ID
            Text(
              'ID: ${claim.id}',
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
            ),

            const SizedBox(height: 6),

            // Status & Hops
            Row(
              children: [
                Text(
                  'Status: ${claim.status.name.toUpperCase()}',
                  style: const TextStyle(
                    color: AppColors.primaryText,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  'Hops left: ${claim.hopLimit}',
                  style: const TextStyle(
                    color: AppColors.secondaryText,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),

            // Payload-specific info
            if (claim.payload is SosPayload) ...[
              const SizedBox(height: 8),
              _buildPayloadInfo(claim.payload as SosPayload),
            ] else if (claim.payload is SosProxyPayload) ...[
              const SizedBox(height: 8),
              _buildProxyInfo(claim.payload as SosProxyPayload),
            ] else if (claim.payload is HazardReportPayload) ...[
              const SizedBox(height: 8),
              _buildHazardInfo(claim.payload as HazardReportPayload),
            ] else if (claim.payload is ResourcePayload) ...[
              const SizedBox(height: 8),
              _buildResourceInfo(claim.payload as ResourcePayload),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPayloadInfo(SosPayload payload) {
    return Row(
      children: [
        const Icon(Icons.location_on_outlined, size: 16, color: AppColors.secondaryText),
        const SizedBox(width: 4),
        Text(
          '${payload.location.lat.toStringAsFixed(4)}, ${payload.location.lon.toStringAsFixed(4)}',
          style: const TextStyle(
            color: AppColors.primaryText,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (payload.headcount != null) ...[
          const SizedBox(width: 14),
          const Icon(Icons.people_outline, size: 16, color: AppColors.secondaryText),
          const SizedBox(width: 4),
          Text(
            _headcountLabel(payload.headcount!),
            style: const TextStyle(
              color: AppColors.primaryText,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProxyInfo(SosProxyPayload payload) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.person_pin_circle_outlined, size: 16, color: AppColors.darkRed),
            const SizedBox(width: 4),
            Text(
              'Proxy SOS — reported for someone else',
              style: TextStyle(
                color: AppColors.darkRed.withAlpha(220),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (payload.proxyNote != null) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.creamBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Text(
              '"${payload.proxyNote}"',
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

  Widget _buildHazardInfo(HazardReportPayload payload) {
    return Row(
      children: [
        const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.amberDark),
        const SizedBox(width: 4),
        Text(
          '${payload.hazardType.name.toUpperCase()} — ${payload.confirmationCount} reports',
          style: const TextStyle(
            color: AppColors.primaryText,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildResourceInfo(ResourcePayload payload) {
    // Availability is computed, never stored — CLAUDE.md §7, CLAIM_SCHEMA.md §8.1.
    final available = payload.available;
    return Row(
      children: [
        Icon(
          _iconForResource(payload.category),
          size: 16,
          color: AppColors.darkGreen,
        ),
        const SizedBox(width: 4),
        Text(
          '${payload.category.name} — $available available (${payload.pledgedCount} pledged, ${payload.claimedReports} claimed)',
          style: const TextStyle(
            color: AppColors.primaryText,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildBadge(String label, Color fg, Color bg, Color border) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  // ─── Label & Color Helpers ──────────────────────────────────────

  static Color _colorForType(ClaimType type) => switch (type) {
        ClaimType.sos => AppColors.darkRed,
        ClaimType.sosProxy => AppColors.darkRed,
        ClaimType.hazardReport => AppColors.amberDark,
        ClaimType.resource => AppColors.darkGreen,
      };

  static IconData _iconForType(ClaimType type) => switch (type) {
        ClaimType.sos => Icons.sos_rounded,
        ClaimType.sosProxy => Icons.person_pin_circle,
        ClaimType.hazardReport => Icons.report_problem_outlined,
        ClaimType.resource => Icons.inventory_2_outlined,
      };

  static String _labelForType(ClaimType type) => switch (type) {
        ClaimType.sos => 'SOS',
        ClaimType.sosProxy => 'Proxy SOS',
        ClaimType.hazardReport => 'Hazard Report',
        ClaimType.resource => 'Resource',
      };

  static ({String label, Color fg, Color bg, Color border}) _trustConfig(ClaimTrust trust) =>
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

  static ({String label, Color fg, Color bg, Color border}) _priorityConfig(DispatchPriority priority) =>
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

  static String _headcountLabel(HeadcountBucket bucket) => switch (bucket) {
        HeadcountBucket.twoToFive => '2-5 people',
        HeadcountBucket.sixToFifteen => '6-15 people',
        HeadcountBucket.fifteenPlus => '15+ people',
      };

  static IconData _iconForResource(ResourceCategory cat) => switch (cat) {
        ResourceCategory.foodWater => Icons.restaurant,
        ResourceCategory.shelter => Icons.home,
        ResourceCategory.medical => Icons.medical_services,
        ResourceCategory.equipment => Icons.build,
      };
}
