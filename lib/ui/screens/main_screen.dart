import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mayday/common/debug_claim_seeder.dart';
import 'package:mayday/ui/forms/contribute_form_sheet.dart';
import 'package:mayday/ui/forms/report_form_sheet.dart';
import 'package:mayday/ui/forms/rescue_form_sheet.dart';
import 'package:mayday/ui/map/claim_detail_sheet.dart';
import 'package:mayday/ui/map/claim_pin_widget.dart';
import 'package:mayday/ui/map/offline_map_manager.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/screens/volunteer_ops_screen.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Main screen — PERSON_C.md §3 Day 4, MAYDAY_PROJECT_CONTEXT.md §3.
///
/// Single offline map with a toggle between two views:
/// - Emergency layer — active SOS pins + hazard report pins
/// - Resource layer — Food & Water, Shelter, Medical, Equipment pins
///
/// Bottom sheet with three primary actions: Rescue, Report, Contribute.
///
/// Visual Design:
/// - Header & Structural Elements: Deep Navy Blue (#12355B)
/// - Background: Very Light Cream (#FFFDF5)
/// - Bottom Actions Surface: Pure White (#FFFFFF) with clean border (#D8E2EC)
/// - Rescue (Emergency): Dark Red (#B42318)
/// - Report (Hazard): Amber (#B45309 / #F2B134)
/// - Contribute (Resource): Dark Green (#18794E)
class MainScreen extends StatefulWidget {
  static const routeName = '/main';

  final bool isVolunteer;

  const MainScreen({super.key, required this.isVolunteer});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class MainScreenPinItem {
  final Claim claim;
  final Point<num> screenPoint;

  MainScreenPinItem({required this.claim, required this.screenPoint});
}

class MainScreenClusterItem {
  final List<Claim> claims;
  final Point<num> screenPoint;

  MainScreenClusterItem({required this.claims, required this.screenPoint});
}

class _MainScreenState extends State<MainScreen> {
  /// Emergency layer (SOS + hazard) or Resource layer.
  /// Toggle built in Day 4 — PERSON_C.md §3 Day 4.
  bool _showEmergencyLayer = true;

  /// Offline map tile manager — copies bundled .mbtiles from assets to
  /// the device’s writable directory so MapLibre can read them.
  /// No remote URLs, no network calls. — PERSON_C.md §3 Day 2.
  final OfflineMapManager _mapManager = OfflineMapManager();
  bool _mapReady = false;
  String? _mapError;
  MapLibreMapController? _mapController;

  /// Active claims subscription from ClaimRepository.
  StreamSubscription<List<Claim>>? _claimsSubscription;
  List<Claim> _allClaims = [];

  /// Screen-projected pins and clusters for the current view.
  List<MainScreenPinItem> _renderedPins = [];
  List<MainScreenClusterItem> _renderedClusters = [];
  double _currentZoom = 12.0;

  /// Safety net flag to prevent infinite retry loops if initial projection fails
  bool _hasRetriedInitialProjection = false;

  /// Guards against concurrent _updatePinScreenPositions() runs.
  /// Without this, a slow projection loop (120 × async toScreenLocation) can
  /// stack on itself if the stream emits or camera-idle fires mid-flight,
  /// causing compounding lag during panning.
  bool _isProjectionRunning = false;

  /// Debounce timer for camera-idle triggered re-projection.
  /// Prevents the overlay from recalculating on every intermediate idle
  /// event that MapLibre emits during a fling/deceleration.
  Timer? _projectionDebounce;

  @override
  void initState() {
    super.initState();
    _initializeMap();
    _subscribeToClaims();
  }

  void _subscribeToClaims() {
    _claimsSubscription = ClaimRepository().watchActiveClaims().listen(
      (claims) {
        if (!mounted) return;
        setState(() {
          _allClaims = claims;
        });
        _updatePinScreenPositions();
      },
      onError: (e) {
        debugPrint('[MainScreen] Error from watchActiveClaims stream: $e');
      },
    );
  }

  Future<void> _initializeMap() async {
    debugPrint('[MainScreen] _initializeMap started');
    try {
      await _mapManager.initialize();
      if (mounted) {
        setState(() => _mapReady = true);
        debugPrint('[MainScreen] _initializeMap finished, _mapReady=true');
      }
    } catch (e, st) {
      debugPrint('[MainScreen] Map initialization error: $e\n$st');
      if (mounted) {
        setState(() {
          _mapError = '$e';
        });
      }
    }
  }

  /// Returns the cluster half-extent (in logical pixels) for a given claim type.
  ///
  /// SOS/Proxy SOS render as ~48px diameter circles → half-extent 24px.
  /// Hazard and Resource render as label pills whose width depends on text;
  /// the longest hazard name ("structuralDamage") renders ~110px wide, so
  /// we use 60px half-extent. Resource uses the same pill shape.
  ///
  /// Cluster distance = half-extent(A) + half-extent(B) + 8px gutter.
  /// Using fixed 45px for both was too small for label cards: two hazard
  /// cards 40px apart center-to-center are visually fully overlapping.
  static double _pinHalfExtent(ClaimType type) {
    return switch (type) {
      ClaimType.sos => 24.0,
      ClaimType.sosProxy => 24.0,
      ClaimType.hazardReport => 60.0, // pill card ≈ 110–120px wide
      ClaimType.resource => 55.0,    // pill card ≈ 100–110px wide
    };
  }

  /// Projects lat/lon of filtered claims to 2D screen coordinates.
  ///
  /// Fix 1 — In-flight guard: if a projection loop is already running we
  /// skip the new call rather than stacking async work. The in-flight loop
  /// was already operating on the latest _allClaims snapshot (updated
  /// synchronously by the stream listener before calling this), so its
  /// result will be current. A second concurrent loop would only waste
  /// toScreenLocation round-trips and extend the lag.
  ///
  /// Fix 2 — Debounce: camera-idle callers go through _scheduleProjection()
  /// which coalesces rapid consecutive idle events (e.g. during fling
  /// deceleration) into a single run 80ms after the last event.
  Future<void> _updatePinScreenPositions() async {
    // In-flight guard — drop the call if one is already running.
    if (_isProjectionRunning) {
      debugPrint('[MainScreen] _updatePinScreenPositions skipped — already running');
      return;
    }
    _isProjectionRunning = true;

    try {
      debugPrint(
        '[MainScreen] _updatePinScreenPositions called, mapController=${_mapController != null}',
      );
      final controller = _mapController;
      if (controller == null || !mounted) return;

      final zoom = controller.cameraPosition?.zoom ?? _currentZoom;
      _currentZoom = zoom;

      // Filter claims by active layer — PERSON_C.md §3 Day 4
      final filteredClaims = _allClaims.where((c) {
        if (_showEmergencyLayer) {
          return c.type == ClaimType.sos ||
              c.type == ClaimType.sosProxy ||
              c.type == ClaimType.hazardReport;
        } else {
          return c.type == ClaimType.resource;
        }
      }).toList();
      debugPrint('[MainScreen] filteredClaims count: ${filteredClaims.length}');

      // 1. Viewport Culling — only consider claims within or near the visible camera region
      List<Claim> candidateClaims = filteredClaims;
      try {
        final visibleRegion = await controller.getVisibleRegion();
        final latSpan = (visibleRegion.northeast.latitude - visibleRegion.southwest.latitude).abs();
        final lonSpan = (visibleRegion.northeast.longitude - visibleRegion.southwest.longitude).abs();
        // 20% margin around viewport so pins entering the screen edge animate/render seamlessly
        final latMargin = latSpan * 0.20;
        final lonMargin = lonSpan * 0.20;
        final minLat = min(visibleRegion.southwest.latitude, visibleRegion.northeast.latitude) - latMargin;
        final maxLat = max(visibleRegion.southwest.latitude, visibleRegion.northeast.latitude) + latMargin;
        final minLon = min(visibleRegion.southwest.longitude, visibleRegion.northeast.longitude) - lonMargin;
        final maxLon = max(visibleRegion.southwest.longitude, visibleRegion.northeast.longitude) + lonMargin;

        candidateClaims = filteredClaims.where((c) {
          final lat = c.payload.location.lat;
          final lon = c.payload.location.lon;
          return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;
        }).toList();
      } catch (e) {
        debugPrint('[MainScreen] getVisibleRegion failed, falling back to all filtered claims: $e');
      }

      if (!mounted) return;

      final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
      final List<MainScreenPinItem> projectedItems = [];

      if (candidateClaims.isNotEmpty) {
        try {
          // 2. Vectorized Batched Projection — single platform-channel call instead of N sequential awaits
          final latLngList = candidateClaims
              .map((c) => LatLng(c.payload.location.lat, c.payload.location.lon))
              .toList();
          final physicalPositions = await controller.toScreenLocationBatch(latLngList);

          for (int i = 0; i < candidateClaims.length && i < physicalPositions.length; i++) {
            final physicalPos = physicalPositions[i];
            final logicalPos = Point<num>(
              physicalPos.x / pixelRatio,
              physicalPos.y / pixelRatio,
            );
            projectedItems.add(
              MainScreenPinItem(claim: candidateClaims[i], screenPoint: logicalPos),
            );
          }
        } catch (e) {
          debugPrint('[MainScreen] toScreenLocationBatch failed, falling back to sequential: $e');
          for (final claim in candidateClaims) {
            try {
              final physicalPos = await controller.toScreenLocation(
                LatLng(claim.payload.location.lat, claim.payload.location.lon),
              );
              final logicalPos = Point<num>(
                physicalPos.x / pixelRatio,
                physicalPos.y / pixelRatio,
              );
              projectedItems.add(
                MainScreenPinItem(claim: claim, screenPoint: logicalPos),
              );
            } catch (err) {
              debugPrint('[MainScreen] toScreenLocation failed for ${claim.id}: $err');
            }
          }
        }
      }
      debugPrint('[MainScreen] projectedItems count: ${projectedItems.length}');

      if (!mounted) return;

      // Single retry safety net if initial style projection was not yet reliable
      if (projectedItems.isEmpty &&
          filteredClaims.isNotEmpty &&
          !_hasRetriedInitialProjection) {
        _hasRetriedInitialProjection = true;
        debugPrint('[MainScreen] Scheduling retry projection in 300ms');
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _isProjectionRunning = false; // release guard so retry can run
            _updatePinScreenPositions();
          }
        });
        return;
      }

      // Reset retry flag once pins are successfully projected
      if (projectedItems.isNotEmpty) {
        _hasRetriedInitialProjection = false;
      }

      // Cluster nearby pins if zoom is low (zoom < 11.5)
      // Display-only per CLAIM_SCHEMA.md §2; underlying records remain separate.
      //
      // Fix 3 — Per-type cluster threshold:
      // dist threshold = halfExtent(A) + halfExtent(B) + 8px gutter.
      // Previously a fixed 45px was used, which only worked for SOS circles.
      // Hazard label cards are ~110px wide; two hazard pins 40px apart
      // passed the old test but were fully overlapping on screen.
      if (_currentZoom < 11.5) {
        final List<MainScreenClusterItem> clusters = [];
        final List<MainScreenPinItem> individualPins = [];
        final Set<int> clusteredIndices = {};

        for (int i = 0; i < projectedItems.length; i++) {
          if (clusteredIndices.contains(i)) continue;

          final current = projectedItems[i];
          final List<Claim> group = [current.claim];
          num totalX = current.screenPoint.x;
          num totalY = current.screenPoint.y;

          for (int j = i + 1; j < projectedItems.length; j++) {
            if (clusteredIndices.contains(j)) continue;

            final candidate = projectedItems[j];
            final dx = current.screenPoint.x - candidate.screenPoint.x;
            final dy = current.screenPoint.y - candidate.screenPoint.y;
            final dist = sqrt(dx * dx + dy * dy);

            // Dynamic threshold: sum of each pin's half-extent + 8px gutter
            final threshold =
                _pinHalfExtent(current.claim.type) +
                _pinHalfExtent(candidate.claim.type) +
                8.0;

            if (dist < threshold) {
              group.add(candidate.claim);
              totalX += candidate.screenPoint.x;
              totalY += candidate.screenPoint.y;
              clusteredIndices.add(j);
            }
          }

          if (group.length > 1) {
            clusteredIndices.add(i);
            clusters.add(
              MainScreenClusterItem(
                claims: group,
                screenPoint: Point(totalX / group.length, totalY / group.length),
              ),
            );
          } else {
            individualPins.add(current);
          }
        }

        if (mounted) {
          setState(() {
            _renderedPins = individualPins;
            _renderedClusters = clusters;
          });
        }
      } else {
        // Zoomed in: render every pin individually at its precise coordinates
        if (mounted) {
          setState(() {
            _renderedPins = projectedItems;
            _renderedClusters = [];
          });
        }
      }
    } finally {
      _isProjectionRunning = false;
    }
  }

  /// Debounced entry-point for camera-idle events.
  /// Coalesces rapid consecutive idle events (fling deceleration) into a
  /// single projection run 80ms after the last event fires.
  void _scheduleProjection() {
    _projectionDebounce?.cancel();
    _projectionDebounce = Timer(const Duration(milliseconds: 80), () {
      if (mounted) _updatePinScreenPositions();
    });
  }

  @override
  void dispose() {
    _projectionDebounce?.cancel();
    _claimsSubscription?.cancel();
    _mapController?.dispose();
    _mapManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.creamBackground,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        elevation: 0,
        title: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: kDebugMode
                  ? () async {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Seeding 120 synthetic claims into SQLite...'),
                          duration: Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      final count = await DebugClaimSeeder.seedSyntheticClaims();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Debug: $count synthetic claims seeded into SQLite.'),
                            backgroundColor: AppColors.darkGreen,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    }
                  : null,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    color: Colors.white,
                    size: 22,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'MayDay',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // Layer toggle chip — Emergency / Resource
            _buildLayerToggle(),
          ],
        ),
        actions: [
          // Volunteer-only ops screen access
          if (widget.isVolunteer)
            IconButton(
              icon: const Icon(
                Icons.assignment_outlined,
                color: Colors.white,
              ),
              tooltip: 'Volunteer Ops',
              onPressed: () {
                Navigator.pushNamed(context, VolunteerOpsScreen.routeName);
              },
            ),
        ],
      ),
      body: Stack(
        children: [
          // ─── Offline map (Day 2) — MapLibre GL + .mbtiles ───────────
          // No remote tile URL, no remote style URL, no network calls.
          // Test with the device in airplane mode. — PERSON_C.md §3 Day 2.
          _mapReady
              ? MapLibreMap(
                  styleString: _mapManager.buildLocalStyleJson(),
                  initialCameraPosition: const CameraPosition(
                    // Bengaluru area — matches bundled placeholder .mbtiles
                    target: LatLng(12.9716, 77.5946),
                    zoom: 12.0,
                  ),
                  trackCameraPosition: true,
                  myLocationEnabled: false, // no GPS needed for MVP
                  onMapCreated: (controller) {
                    debugPrint('[MainScreen] onMapCreated fired');
                    _mapController = controller;
                    _updatePinScreenPositions();
                  },
                  onStyleLoadedCallback: () {
                    debugPrint('[MainScreen] style loaded callback fired');
                    _updatePinScreenPositions();
                  },
                  onCameraIdle: () {
                    // Debounced — coalesces rapid idle events during fling/deceleration.
                    _scheduleProjection();
                  },
                )
              : Center(
                  child: _mapError != null
                      ? Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: SelectableText(
                            'Map Init Error:\n$_mapError',
                            style: const TextStyle(
                              color: AppColors.darkRed,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : const CircularProgressIndicator(
                          color: AppColors.strongBlue,
                        ),
                ),

          // ─── Interactive Pin Layer (Day 4) ────────────────────────
          // Rendered on top of the MapLibre surface in Flutter widget tree
          if (_mapReady) ..._buildPinOverlayWidgets(),

          // ─── Bottom Action Bar (Day 3) ───────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomActions(context),
          ),
        ],
      ),
    );
  }

  /// Builds Positioned widgets for each individual pin and cluster.
  List<Widget> _buildPinOverlayWidgets() {
    final List<Widget> widgets = [];

    // Individual pins — keyed by ValueKey(claim.id) to update in-place without flickering
    for (final item in _renderedPins) {
      final logicalX = item.screenPoint.x.toDouble();
      final logicalY = item.screenPoint.y.toDouble();
      final double halfWidth = _pinHalfExtent(item.claim.type);
      final double halfHeight = switch (item.claim.type) {
        ClaimType.sos || ClaimType.sosProxy => 24.0,
        ClaimType.hazardReport || ClaimType.resource => 18.0,
      };

      widgets.add(
        Positioned(
          key: ValueKey('pos_${item.claim.id}'),
          left: logicalX - halfWidth,
          top: logicalY - halfHeight,
          child: ClaimPinWidget(
            key: ValueKey(item.claim.id),
            claim: item.claim,
            onTap: () {
              ClaimDetailSheet.show(context, item.claim);
            },
          ),
        ),
      );
    }

    // Clustered pins at low zoom
    for (final cluster in _renderedClusters) {
      final logicalX = cluster.screenPoint.x.toDouble();
      final logicalY = cluster.screenPoint.y.toDouble();
      final clusterId = cluster.claims.map((c) => c.id).join('_');

      widgets.add(
        Positioned(
          key: ValueKey('cluster_pos_$clusterId'),
          left: logicalX - 40,
          top: logicalY - 18,
          child: ClusterPinWidget(
            key: ValueKey('cluster_$clusterId'),
            claims: cluster.claims,
            onTap: () {
              ClaimDetailSheet.showCluster(context, cluster.claims);
            },
          ),
        ),
      );
    }

    return widgets;
  }

  /// High-contrast layer toggle integrated directly into the Deep Navy AppBar.
  Widget _buildLayerToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF0C2440),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1D4770), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _layerChip(
            label: 'Emergency',
            icon: Icons.warning_amber_rounded,
            isSelected: _showEmergencyLayer,
            selectedBgColor: AppColors.darkRed,
            selectedTextColor: Colors.white,
            onTap: () {
              if (!_showEmergencyLayer) {
                setState(() => _showEmergencyLayer = true);
                _updatePinScreenPositions();
              }
            },
          ),
          _layerChip(
            label: 'Resource',
            icon: Icons.inventory_2_outlined,
            isSelected: !_showEmergencyLayer,
            selectedBgColor: AppColors.darkGreen,
            selectedTextColor: Colors.white,
            onTap: () {
              if (_showEmergencyLayer) {
                setState(() => _showEmergencyLayer = false);
                _updatePinScreenPositions();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _layerChip({
    required String label,
    required IconData icon,
    required bool isSelected,
    required Color selectedBgColor,
    required Color selectedTextColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? selectedBgColor : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? selectedTextColor : Colors.white70,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? selectedTextColor : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Bottom action bar with Rescue / Report / Contribute.
  /// Clear, high-contrast, accessible cards on a clean white surface.
  Widget _buildBottomActions(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: const Border(
          top: BorderSide(color: AppColors.borderSubtle, width: 1.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // ─── Rescue (Emergency - Dark Red #B42318) ───────────────
          _actionButton(
            icon: Icons.sos_rounded,
            label: 'Rescue',
            textColor: AppColors.darkRed,
            iconColor: AppColors.darkRed,
            bgColor: AppColors.redLight,
            borderColor: AppColors.darkRed.withAlpha(120),
            onTap: () {
              RescueFormSheet.show(context);
            },
          ),

          // ─── Report (Warning - Amber #B45309 / #F2B134) ─────────
          _actionButton(
            icon: Icons.report_problem_outlined,
            label: 'Report',
            textColor: AppColors.amberDark,
            iconColor: AppColors.amberDark,
            bgColor: AppColors.amberLight,
            borderColor: AppColors.amberYellow,
            onTap: () {
              ReportFormSheet.show(context);
            },
          ),

          // ─── Contribute (Safe/Resource - Dark Green #18794E) ────
          _actionButton(
            icon: Icons.volunteer_activism_outlined,
            label: 'Contribute',
            textColor: AppColors.darkGreen,
            iconColor: AppColors.darkGreen,
            bgColor: AppColors.greenLight,
            borderColor: AppColors.darkGreen.withAlpha(120),
            onTap: () {
              // TODO: This is a temporary Week 1 stand-in for `nodeTrust` which won't exist until Phase 4 (identity/vouching).
              // See PERSON_C.md §6 for details.
              if (!widget.isVolunteer) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text(
                      'Only verified volunteers can contribute resources',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    backgroundColor: AppColors.deepNavy,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
                return;
              }
              ContributeFormSheet.show(context);
            },
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color textColor,
    required Color iconColor,
    required Color bgColor,
    required Color borderColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor, width: 1.5),
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
