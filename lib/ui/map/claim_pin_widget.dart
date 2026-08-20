import 'package:flutter/material.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Custom pin widget rendered on top of the MapLibre map — PERSON_C.md §3 Day 4.
///
/// Invariants & Rules:
/// - Distinct icon & styling per ClaimType (SOS, Proxy SOS, Hazard, Resource).
/// - Trust tier appearance: UNCONFIRMED (faint/0.55 opacity), CORROBORATED (full opacity),
///   GROUND_CONFIRMED (distinct double-ring + verified shield badge). Read directly from
///   MockClaim.claimTrust. — CLAIM_SCHEMA.md §3.
/// - Aging SOS: gets MORE visual urgency over time (pulsing animation, beacon halo),
///   scaled continuously across three tiers (1hr / 3hr / 6hr+) —
///   never fades. — CLAUDE.md §2.3.
/// - Proxy SOS: visually distinct from self-raised SOS via dual-border + proxy badge.
/// - Hazard pins: show confirmation count badge directly from HazardReportPayload.
/// - Resource pins: show single available count. Range display ('2–6 packets') is
///   blocked on B's replica-conflict data (CLAIM_SCHEMA.md §8.1) — not available
///   in Week 1 mock data.
class ClaimPinWidget extends StatefulWidget {
  final MockClaim claim;
  final VoidCallback onTap;

  const ClaimPinWidget({
    super.key,
    required this.claim,
    required this.onTap,
  });

  @override
  State<ClaimPinWidget> createState() => _ClaimPinWidgetState();
}

class _ClaimPinWidgetState extends State<ClaimPinWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  /// Whether this SOS/SOS_PROXY is aging (active and older than 1 hour).
  bool get _isAgingSos => ClaimDisplayHelpers.isAgingSos(widget.claim);

  /// Returns the aging urgency tier for scaling visual intensity.
  int get _agingTier => ClaimDisplayHelpers.agingTier(widget.claim);

  /// Bucketed relative-time label for the aging badge.
  String get _agingLabel => ClaimDisplayHelpers.agingBadgeLabel(widget.claim.mockCreatedAt);

  /// Pulse animation speed scales with aging tier.
  Duration get _pulseDuration => switch (_agingTier) {
    1 => const Duration(milliseconds: 1500),  // slow
    2 => const Duration(milliseconds: 1000),  // medium
    3 => const Duration(milliseconds: 700),   // fast — maximum urgency
    _ => const Duration(milliseconds: 1500),
  };

  /// Halo expansion range scales with aging tier.
  double get _pulseEnd => switch (_agingTier) {
    1 => 1.15,  // subtle
    2 => 1.25,  // moderate
    3 => 1.40,  // intense — visibly more urgent than tier 1/2
    _ => 1.15,
  };

  /// Halo opacity scales with aging tier.
  int get _haloAlpha => switch (_agingTier) {
    1 => 35,   // subtle
    2 => 60,   // moderate
    3 => 90,   // intense
    _ => 35,
  };

  int get _haloBorderAlpha => switch (_agingTier) {
    1 => 90,
    2 => 140,
    3 => 200,
    _ => 90,
  };


  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: _pulseDuration,
    );

    _pulseAnimation = Tween<double>(begin: 0.95, end: _pulseEnd).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (_isAgingSos) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(ClaimPinWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isAgingSos && !_pulseController.isAnimating) {
      // Reconfigure pulse speed/range for current aging tier
      _pulseController.duration = _pulseDuration;
      _pulseAnimation = Tween<double>(begin: 0.95, end: _pulseEnd).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
      );
      _pulseController.repeat(reverse: true);
    } else if (!_isAgingSos && _pulseController.isAnimating) {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final claim = widget.claim;

    // Trust tier opacity — UNCONFIRMED faint, CORROBORATED/GROUND_CONFIRMED full opacity
    final double opacity = switch (claim.claimTrust) {
      ClaimTrust.unconfirmed => 0.55,
      ClaimTrust.corroborated => 1.0,
      ClaimTrust.groundConfirmed => 1.0,
    };

    Widget pinBody;
    switch (claim.type) {
      case ClaimType.sos:
        pinBody = _buildSosPin(claim, isProxy: false);
        break;
      case ClaimType.sosProxy:
        pinBody = _buildSosPin(claim, isProxy: true);
        break;
      case ClaimType.hazardReport:
        pinBody = _buildHazardPin(claim);
        break;
      case ClaimType.resource:
        pinBody = _buildResourcePin(claim);
        break;
    }

    if (_isAgingSos) {
      return AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Opacity(
            opacity: opacity,
            child: GestureDetector(
              onTap: widget.onTap,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // Pulsing beacon halo for aging SOS — intensity scales
                  // with _agingTier (1hr/3hr/6hr+). A 6-hour SOS pulses
                  // faster and larger than a 1-hour SOS.
                  Container(
                    width: 54 * _pulseAnimation.value,
                    height: 54 * _pulseAnimation.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.darkRed.withAlpha(_haloAlpha),
                      border: Border.all(
                        color: AppColors.darkRed.withAlpha(_haloBorderAlpha),
                        width: 1.5,
                      ),
                    ),
                  ),
                  pinBody,
                ],
              ),
            ),
          );
        },
      );
    }

    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        onTap: widget.onTap,
        child: pinBody,
      ),
    );
  }

  // ─── SOS & Proxy SOS Pin ───────────────────────────────────────────
  Widget _buildSosPin(MockClaim claim, {required bool isProxy}) {
    final payload = claim.payload;
    final isGroundConfirmed = claim.claimTrust == ClaimTrust.groundConfirmed;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        shape: BoxShape.circle,
        border: Border.all(
          color: isGroundConfirmed ? AppColors.darkGreen : AppColors.darkRed,
          width: isGroundConfirmed ? 3.0 : (isProxy ? 2.0 : 2.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(3),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Inner icon container
          Container(
            width: isProxy ? 36 : 38,
            height: isProxy ? 36 : 38,
            decoration: BoxDecoration(
              color: isProxy ? AppColors.redLight : AppColors.darkRed,
              shape: BoxShape.circle,
              border: isProxy
                  ? Border.all(color: AppColors.darkRed, width: 1.5)
                  : null,
            ),
            child: Center(
              child: Icon(
                isProxy ? Icons.person_pin_circle_outlined : Icons.sos_rounded,
                color: isProxy ? AppColors.darkRed : Colors.white,
                size: isProxy ? 22 : 22,
              ),
            ),
          ),

          // Proxy badge indicator (top right) — distinguishes Proxy SOS
          if (isProxy)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.amberDark,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: const Text(
                  'PROXY',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),

          // Ground confirmed check badge
          if (isGroundConfirmed)
            Positioned(
              bottom: -4,
              right: -4,
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: const BoxDecoration(
                  color: AppColors.darkGreen,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, size: 10, color: Colors.white),
              ),
            ),

          // Group headcount badge (if group SOS)
          if (payload is SosPayload && payload.headcount != null)
            Positioned(
              bottom: -8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.deepNavy,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: Text(
                  _headcountShort(payload.headcount!),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

          // Aging indicator badge — shows bucketed relative time, never a
          // precise timestamp — CLAIM_SCHEMA.md §4.
          if (_isAgingSos)
            Positioned(
              top: -8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.darkRed,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: Text(
                  _agingLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 7,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Hazard Pin ───────────────────────────────────────────────────
  Widget _buildHazardPin(MockClaim claim) {
    final payload = claim.payload as HazardReportPayload;
    final isGroundConfirmed = claim.claimTrust == ClaimTrust.groundConfirmed;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isGroundConfirmed ? AppColors.darkGreen : AppColors.amberDark,
          width: isGroundConfirmed ? 2.5 : 1.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(30),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(3),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.amberLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _hazardIcon(payload.hazardType),
                  color: AppColors.amberDark,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  payload.hazardType.name.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.amberDark,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          // Confirmation count badge ("12 reports") — CLAIM_SCHEMA.md §8
          Positioned(
            top: -8,
            right: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.deepNavy,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 1),
              ),
              child: Text(
                '${payload.confirmationCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),

          // Ground confirmed check badge
          if (isGroundConfirmed)
            Positioned(
              bottom: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: const BoxDecoration(
                  color: AppColors.darkGreen,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, size: 9, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Resource Pin ─────────────────────────────────────────────────
  Widget _buildResourcePin(MockClaim claim) {
    final payload = claim.payload as ResourcePayload;
    final isGroundConfirmed = claim.claimTrust == ClaimTrust.groundConfirmed;

    // Range display ('2–6 packets') is blocked on B's replica-conflict
    // data (CLAIM_SCHEMA.md §8.1) — not available in Week 1 mock data.
    // Showing single available count until real uncertainty data exists.
    final availableText = '${payload.available}';

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isGroundConfirmed ? AppColors.deepNavy : AppColors.darkGreen,
          width: isGroundConfirmed ? 2.5 : 1.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(30),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(3),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.greenLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _resourceIcon(payload.category),
                  color: AppColors.darkGreen,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  availableText,
                  style: const TextStyle(
                    color: AppColors.darkGreen,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          // Ground confirmed check badge
          if (isGroundConfirmed)
            Positioned(
              bottom: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: const BoxDecoration(
                  color: AppColors.deepNavy,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.verified, size: 10, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────
  static IconData _hazardIcon(HazardType type) => ClaimDisplayHelpers.iconForHazard(type);

  static IconData _resourceIcon(ResourceCategory cat) => ClaimDisplayHelpers.iconForResource(cat);

  static String _headcountShort(HeadcountBucket bucket) => ClaimDisplayHelpers.headcountShort(bucket);
}

/// Clustered pin marker rendered at low zoom — CLAIM_SCHEMA.md §2, PERSON_C.md §6.
/// Display-only grouping; underlying records stay separate.
class ClusterPinWidget extends StatelessWidget {
  final List<MockClaim> claims;
  final VoidCallback onTap;

  const ClusterPinWidget({
    super.key,
    required this.claims,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasSos = claims.any(
        (c) => c.type == ClaimType.sos || c.type == ClaimType.sosProxy);
    final count = claims.length;

    final bgColor = hasSos ? AppColors.darkRed : AppColors.deepNavy;
    final borderColor = hasSos ? AppColors.redLight : AppColors.blueLight;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(45),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasSos ? Icons.sos_rounded : Icons.place,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              hasSos ? '$count SOS' : '$count Claims',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
