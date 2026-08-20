import 'dart:math';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
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
  final MockClaim claim;
  final Point<num> screenPoint;

  MainScreenPinItem({required this.claim, required this.screenPoint});
}

class MainScreenClusterItem {
  final List<MockClaim> claims;
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

  /// All mock claims for Week 1 — will be replaced by real SQLite queries in Week 2.
  final List<MockClaim> _allClaims = MockData.generateMockClaims();

  /// Screen-projected pins and clusters for the current view.
  List<MainScreenPinItem> _renderedPins = [];
  List<MainScreenClusterItem> _renderedClusters = [];
  double _currentZoom = 12.0;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    try {
      await _mapManager.initialize();
      if (mounted) {
        setState(() => _mapReady = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updatePinScreenPositions();
        });
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

  /// Projects lat/lon of filtered claims to 2D screen coordinates on camera change.
  /// Handles zoom-based clustering per CLAIM_SCHEMA.md §2 and PERSON_C.md §6.
  Future<void> _updatePinScreenPositions() async {
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

    final List<MainScreenPinItem> projectedItems = [];
    for (final claim in filteredClaims) {
      try {
        final screenPos = await controller.toScreenLocation(
          LatLng(claim.payload.location.lat, claim.payload.location.lon),
        );
        projectedItems.add(
          MainScreenPinItem(claim: claim, screenPoint: screenPos),
        );
      } catch (e) {
        // Map controller may still be initializing screen projection
      }
    }

    if (!mounted) return;

    // Cluster nearby pins if zoom is low (zoom < 11.5)
    // Display-only per CLAIM_SCHEMA.md §2; underlying records remain separate.
    if (_currentZoom < 11.5) {
      final List<MainScreenClusterItem> clusters = [];
      final List<MainScreenPinItem> individualPins = [];
      final Set<int> clusteredIndices = {};

      for (int i = 0; i < projectedItems.length; i++) {
        if (clusteredIndices.contains(i)) continue;

        final current = projectedItems[i];
        final List<MockClaim> group = [current.claim];
        num totalX = current.screenPoint.x;
        num totalY = current.screenPoint.y;

        for (int j = i + 1; j < projectedItems.length; j++) {
          if (clusteredIndices.contains(j)) continue;

          final candidate = projectedItems[j];
          final dx = current.screenPoint.x - candidate.screenPoint.x;
          final dy = current.screenPoint.y - candidate.screenPoint.y;
          final dist = sqrt(dx * dx + dy * dy);

          if (dist < 45.0) {
            // Screen cluster threshold
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

      setState(() {
        _renderedPins = individualPins;
        _renderedClusters = clusters;
      });
    } else {
      // Zoomed in: render every pin individually at its precise coordinates
      setState(() {
        _renderedPins = projectedItems;
        _renderedClusters = [];
      });
    }
  }

  @override
  void dispose() {
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
            const Icon(
              Icons.shield_outlined,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 8),
            const Text(
              'MayDay',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 20,
                letterSpacing: 0.5,
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
                    _mapController = controller;
                    _updatePinScreenPositions();
                  },
                  onCameraIdle: () {
                    _updatePinScreenPositions();
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

    // Individual pins
    for (final item in _renderedPins) {
      widgets.add(
        Positioned(
          left: item.screenPoint.x - 24,
          top: item.screenPoint.y - 24,
          child: ClaimPinWidget(
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
      widgets.add(
        Positioned(
          left: cluster.screenPoint.x - 40,
          top: cluster.screenPoint.y - 18,
          child: ClusterPinWidget(
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
