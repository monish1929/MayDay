import 'package:flutter/material.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Bottom sheet displaying the details of a tapped claim or cluster — PERSON_C.md §3 Day 4.
class ClaimDetailSheet extends StatelessWidget {
  final Claim? singleClaim;
  final List<Claim>? clusterClaims;

  const ClaimDetailSheet.single({
    super.key,
    required Claim claim,
  })  : singleClaim = claim,
        clusterClaims = null;

  const ClaimDetailSheet.cluster({
    super.key,
    required List<Claim> claims,
  })  : singleClaim = null,
        clusterClaims = claims;

  static Future<void> show(BuildContext context, Claim claim) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ClaimDetailSheet.single(claim: claim),
    );
  }

  static Future<void> showCluster(BuildContext context, List<Claim> claims) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ClaimDetailSheet.cluster(claims: claims),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    if (clusterClaims != null) {
      return _buildClusterView(context, clusterClaims!, bottomInset);
    }

    return _buildSingleClaimView(context, singleClaim!, bottomInset);
  }

  Widget _buildClusterView(
      BuildContext context, List<Claim> claims, double bottomInset) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDragHandle(),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.redLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.layers_outlined,
                    color: AppColors.darkRed, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${claims.length} Nearby Claims (Clustered)',
                      style: const TextStyle(
                        color: AppColors.primaryText,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Records stay separate by design (CLAIM_SCHEMA.md §2)',
                      style: TextStyle(
                        color: AppColors.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: AppColors.secondaryText),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: claims.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final claim = claims[index];
                return _buildClaimCard(claim);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleClaimView(
      BuildContext context, Claim claim, double bottomInset) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDragHandle(),
          _buildSingleClaimHeader(context, claim),
          const SizedBox(height: 16),
          _buildClaimCard(claim),
        ],
      ),
    );
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: AppColors.borderMedium,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildSingleClaimHeader(BuildContext context, Claim claim) {
    final (title, icon, color, bg) = switch (claim.type) {
      ClaimType.sos => ('SOS Rescue Request', Icons.sos_rounded, AppColors.darkRed, AppColors.redLight),
      ClaimType.sosProxy => ('Proxy SOS Request', Icons.person_pin_circle_outlined, AppColors.darkRed, AppColors.redLight),
      ClaimType.hazardReport => ('Hazard Report', Icons.report_problem_outlined, AppColors.amberDark, AppColors.amberLight),
      ClaimType.resource => ('Resource Supply Point', Icons.inventory_2_outlined, AppColors.darkGreen, AppColors.greenLight),
    };

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withAlpha(80)),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
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
        IconButton(
          icon: const Icon(Icons.close, color: AppColors.secondaryText),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _buildClaimCard(Claim claim) {
    final trustConfig = ClaimDisplayHelpers.trustConfig(claim.claimTrust);
    final priorityConfig = ClaimDisplayHelpers.priorityConfig(claim.dispatchPriority);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.creamBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Trust & Priority Badges
          Row(
            children: [
              _buildBadge(trustConfig.label, trustConfig.fg, trustConfig.bg, trustConfig.border),
              const SizedBox(width: 6),
              _buildBadge(priorityConfig.label, priorityConfig.fg, priorityConfig.bg, priorityConfig.border),
              const Spacer(),
              Text(
                ClaimDisplayHelpers.relativeTimeLabel(claim.createdAtLogical),
                style: const TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Location coordinates & Hops left
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 14, color: AppColors.secondaryText),
              const SizedBox(width: 4),
              Text(
                '${claim.payload.location.lat.toStringAsFixed(4)}°N, ${claim.payload.location.lon.toStringAsFixed(4)}°E',
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
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

          const Divider(height: 18, color: AppColors.borderSubtle),

          // Specific payload details
          if (claim.payload is SosPayload)
            _buildSosDetails(claim.payload as SosPayload, claim)
          else if (claim.payload is SosProxyPayload)
            _buildProxyDetails(claim.payload as SosProxyPayload, claim)
          else if (claim.payload is HazardReportPayload)
            _buildHazardDetails(claim.payload as HazardReportPayload)
          else if (claim.payload is ResourcePayload)
            _buildResourceDetails(claim.payload as ResourcePayload),
        ],
      ),
    );
  }

  Widget _buildSosDetails(SosPayload payload, Claim claim) {
    final isAging = ClaimDisplayHelpers.isAgingSos(claim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.group_outlined, size: 15, color: AppColors.darkRed),
            const SizedBox(width: 6),
            Text(
              payload.headcount != null
                  ? 'Headcount: ${ClaimDisplayHelpers.headcountLabel(payload.headcount!)}'
                  : 'Individual SOS (Single person)',
              style: const TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (isAging) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.redLight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.darkRed.withAlpha(100)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.darkRed),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Aging SOS: Unresolved for ${ClaimDisplayHelpers.relativeTimeLabel(claim.createdAtLogical)}. Higher response urgency.',
                    style: const TextStyle(
                      color: AppColors.darkRed,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProxyDetails(SosProxyPayload payload, Claim claim) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.person_pin_circle_outlined, size: 15, color: AppColors.darkRed),
            const SizedBox(width: 6),
            Text(
              payload.headcount != null
                  ? 'Proxy SOS — ${ClaimDisplayHelpers.headcountLabel(payload.headcount!)}'
                  : 'Proxy SOS (Reported for neighbour)',
              style: const TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Reporter Device: ${payload.reporterDeviceId}',
          style: const TextStyle(
            color: AppColors.secondaryText,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
        if (payload.proxyNote != null) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
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

  Widget _buildHazardDetails(HazardReportPayload payload) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.amberDark),
            const SizedBox(width: 6),
            Text(
              '${payload.hazardType.name.toUpperCase()} — ${payload.confirmationCount} Reports Merged',
              style: const TextStyle(
                color: AppColors.amberDark,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        if (payload.note != null) ...[
          const SizedBox(height: 6),
          Text(
            '"${payload.note}"',
            style: const TextStyle(
              color: AppColors.primaryText,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildResourceDetails(ResourcePayload payload) {
    // Range display ('2–6 packets') is blocked on B's replica-conflict
    // data (CLAIM_SCHEMA.md §8.1) — not available in Week 1 mock data.
    // Showing single available count until real uncertainty data exists.
    final availableText = '${payload.available}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.inventory_2_outlined, size: 15, color: AppColors.darkGreen),
            const SizedBox(width: 6),
            Text(
              '${payload.category.name.toUpperCase()} — $availableText Units Available',
              style: const TextStyle(
                color: AppColors.darkGreen,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Authoritative pledged: ${payload.pledgedCount} | User claimed reports: ${payload.claimedReports}',
          style: const TextStyle(
            color: AppColors.secondaryText,
            fontSize: 11,
          ),
        ),
      ],
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
}
