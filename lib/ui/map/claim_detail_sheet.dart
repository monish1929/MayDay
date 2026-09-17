import 'package:flutter/material.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Bottom sheet displaying the details of a tapped claim or cluster — PERSON_C.md §3 Day 4.
///
/// Converted from StatelessWidget to StatefulWidget to support the local
/// "report running low" temporary state on resource details (Week 3 Day 2 scaffolding).
class ClaimDetailSheet extends StatefulWidget {
  final Claim? singleClaim;
  final List<Claim>? clusterClaims;
  final bool isVolunteer;

  const ClaimDetailSheet.single({
    super.key,
    required Claim claim,
    this.isVolunteer = false,
  })  : singleClaim = claim,
        clusterClaims = null;

  const ClaimDetailSheet.cluster({
    super.key,
    required List<Claim> claims,
    this.isVolunteer = false,
  })  : singleClaim = null,
        clusterClaims = claims;

  static Future<void> show(BuildContext context, Claim claim, {bool isVolunteer = false}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ClaimDetailSheet.single(claim: claim, isVolunteer: isVolunteer),
    );
  }

  static Future<void> showCluster(BuildContext context, List<Claim> claims, {bool isVolunteer = false}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ClaimDetailSheet.cluster(claims: claims, isVolunteer: isVolunteer),
    );
  }

  @override
  State<ClaimDetailSheet> createState() => _ClaimDetailSheetState();
}

class _ClaimDetailSheetState extends State<ClaimDetailSheet> {
  // TODO: WIRE TO B'S claimedReports FIELD — This is purely local, temporary
  // state so the visual distinction between authoritative count and soft
  // "running low" signal can be reviewed and tested. This counter resets
  // every time the sheet is opened. Once B's data layer exposes a real
  // incrementClaimedReports() method on ClaimRepository, replace this
  // with a call to that method and read claimedReports from the Claim's
  // ResourcePayload instead.
  int _localRunningLowReports = 0;
  
  // TODO: WIRE TO B'S REAL RATE-LIMITING ONCE AVAILABLE - This is temporary local-only logic
  int _localSessionTaps = 0;

  @override
  void initState() {
    super.initState();
    // Seed the local counter from the payload's existing claimedReports
    // so the UI reflects whatever the data layer already has.
    if (widget.singleClaim != null &&
        widget.singleClaim!.payload is ResourcePayload) {
      _localRunningLowReports =
          (widget.singleClaim!.payload as ResourcePayload).claimedReports;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    if (widget.clusterClaims != null) {
      return _buildClusterView(context, widget.clusterClaims!, bottomInset);
    }

    return _buildSingleClaimView(context, widget.singleClaim!, bottomInset);
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
            _buildResourceDetails(claim.payload as ResourcePayload, claim),
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

  Widget _buildResourceDetails(ResourcePayload payload, Claim claim) {
    // Range display ('2–6 packets') is blocked on B's replica-conflict
    // data (CLAIM_SCHEMA.md §8.1) — not available in Week 1 mock data.
    // Showing single available count until real uncertainty data exists.
    final hasLowReports = _localRunningLowReports > 0;
    
    final isOut = payload.available == 0;
    
    final isGroundConfirmed = claim.claimTrust == ClaimTrust.groundConfirmed;
    final trustConfig = ClaimDisplayHelpers.trustConfig(ClaimTrust.groundConfirmed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isGroundConfirmed) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: trustConfig.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: trustConfig.border, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(Icons.verified, size: 18, color: trustConfig.fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Confirmed on-site by a volunteer',
                    style: TextStyle(
                      color: trustConfig.fg,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // ─── Authoritative Pledged Count (primary, confident figure) ───
        Row(
          children: [
            Icon(Icons.inventory_2_outlined, size: 15, color: isOut ? AppColors.secondaryText : AppColors.darkGreen),
            const SizedBox(width: 6),
            Text(
              payload.category.name.toUpperCase(),
              style: TextStyle(
                color: isOut ? AppColors.secondaryText : AppColors.darkGreen,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Big authoritative number — this is the hard, confident count
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isOut ? AppColors.grayLight : AppColors.greenLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isOut ? AppColors.borderSubtle : AppColors.darkGreen.withAlpha(60)),
          ),
          child: Row(
            children: [
              Text(
                '${payload.pledgedCount}',
                style: TextStyle(
                  color: isOut ? AppColors.secondaryText : AppColors.darkGreen,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'units pledged (authoritative)',
                      style: TextStyle(
                        color: isOut ? AppColors.secondaryText : AppColors.darkGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (isOut)
                      Text(
                        'Out — was here, now empty',
                        style: TextStyle(
                          color: AppColors.secondaryText,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // ─── Soft "Running Low" Indicator (only if reports exist) ──────
        if (hasLowReports && !isOut) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.amberLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.amberYellow.withAlpha(120)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.trending_down_rounded,
                  size: 16,
                  color: AppColors.amberDark,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Reportedly running low ($_localRunningLowReports ${_localRunningLowReports == 1 ? 'report' : 'reports'})',
                    style: const TextStyle(
                      color: AppColors.amberDark,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 10),

        // ─── "Report Running Low" Action ───────────────────────────────
        // Available to ANY user — not gated by volunteer status.
        // TODO: WIRE TO B'S REAL RATE-LIMITING ONCE AVAILABLE — Once B's data layer supports it, hook in
        // per-device rate-limiting here to prevent a single device from
        // spamming the running-low counter. For now, there's no guard
        // beyond the local state resetting when the sheet closes.
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _localSessionTaps >= 3 ? null : () {
              // TODO: WIRE TO B'S claimedReports FIELD — Replace this local
              // setState with a real call to B's incrementClaimedReports()
              // on ClaimRepository once it exists. This is purely local state
              // so the UI treatment can be reviewed. No ClaimFactory or
              // ClaimRepository calls here.
              setState(() {
                _localRunningLowReports++;
                _localSessionTaps++;
              });
            },
            icon: Icon(
              Icons.trending_down_rounded,
              size: 16,
              color: _localSessionTaps >= 3 ? AppColors.secondaryText : AppColors.amberDark,
            ),
            label: Text(
              _localSessionTaps >= 3 
                  ? "You've already reported this — thanks, we've got it" 
                  : 'Report running low',
              style: TextStyle(
                color: _localSessionTaps >= 3 ? AppColors.secondaryText : AppColors.amberDark,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: _localSessionTaps >= 3 
                    ? AppColors.borderMedium 
                    : AppColors.amberYellow.withAlpha(150),
              ),
              backgroundColor: _localSessionTaps >= 3 
                  ? AppColors.borderSubtle 
                  : AppColors.amberLight.withAlpha(80),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),

        // ─── Volunteer "Reset count" Action ────────────────────────────
        if (widget.isVolunteer && hasLowReports) ...[
          const SizedBox(height: 10),
          // TODO: This is a temporary Week 1 stand-in for `nodeTrust` which won't exist until Phase 4 (identity/vouching).
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Reset report count?'),
                    content: const Text(
                      'Are you sure you want to reset the running low reports to 0? This indicates that you have physically confirmed stock is fine.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );

                if (confirm == true) {
                  setState(() {
                    _localRunningLowReports = 0;
                    _localSessionTaps = 0;
                  });
                }
              },
              icon: const Icon(
                Icons.refresh,
                size: 16,
                color: AppColors.darkGreen,
              ),
              label: const Text(
                'Reset report count',
                style: TextStyle(
                  color: AppColors.darkGreen,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppColors.darkGreen.withAlpha(150)),
                backgroundColor: AppColors.greenLight.withAlpha(80),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
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
