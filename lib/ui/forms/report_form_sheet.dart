import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mayday/common/device_id.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Bottom sheet form for reporting hazards — PERSON_C.md §3 Day 3, CLAIM_SCHEMA.md §8.
///
/// Features:
/// - Hazard kind selector: flood | roadBlock | structuralDamage | other (HazardType enum)
/// - Optional note: capped at 80 characters (CLAIM_SCHEMA.md §9.2)
/// - On submit: constructs HazardReportPayload, creates Claim via ClaimFactory, and persists via ClaimRepository
class ReportFormSheet extends StatefulWidget {
  final GeoPoint? initialLocation;

  const ReportFormSheet({
    super.key,
    this.initialLocation,
  });

  static Future<dynamic> show(BuildContext context, {GeoPoint? location}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ReportFormSheet(
        initialLocation: location,
      ),
    );
  }

  @override
  State<ReportFormSheet> createState() => _ReportFormSheetState();
}

enum LocationStatus { fetching, success, error, manual }

class _ReportFormSheetState extends State<ReportFormSheet> {
  HazardType _hazardType = HazardType.flood;
  final TextEditingController _noteController = TextEditingController();

  LocationStatus _locationStatus = LocationStatus.fetching;
  GeoPoint? _currentLocation;

  @override
  void initState() {
    super.initState();
    if (widget.initialLocation != null) {
      _currentLocation = widget.initialLocation;
      _locationStatus = LocationStatus.manual;
    } else {
      _fetchLocation();
    }
  }

  Future<void> _fetchLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() => _locationStatus = LocationStatus.error);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (!mounted) return;
          setState(() => _locationStatus = LocationStatus.error);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() => _locationStatus = LocationStatus.error);
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 4),
        ),
      );

      if (!mounted) return;
      setState(() {
        _currentLocation = GeoPoint(lat: position.latitude, lon: position.longitude);
        _locationStatus = LocationStatus.success;
      });
    } catch (e) {
      debugPrint('[_ReportFormSheetState] Location fetch failed: $e');
      if (!mounted) return;
      setState(() => _locationStatus = LocationStatus.error);
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submitForm() async {
    try {
      if (_locationStatus == LocationStatus.fetching) {
        // Still acquiring GPS, prevent submission
        return;
      }

      GeoPoint location;
      if (_currentLocation != null) {
        location = _currentLocation!;
      } else {
        debugPrint('[_ReportFormSheetState] WARNING: Using placeholder Bengaluru location as absolute last resort!');
        location = const GeoPoint(lat: 12.9716, lon: 77.5946);
      }

      final rawNote = _noteController.text.trim();
      final note = rawNote.isEmpty ? null : rawNote;
      final deviceId = await LocalDeviceId.getDeviceId();

      final payload = HazardReportPayload(
        location: location,
        hazardType: _hazardType,
        confirmationCount: 1,
        note: note,
      );

      // Assemble real Claim via ClaimFactory — PERSON_C.md Week 2 Day 1
      final claim = await ClaimFactory.createClaim(
        payload: payload,
        originDeviceId: deviceId,
      );

      // TODO: SIGNING GAP — Claim originated with placeholder signature (Uint8List(0)).
      // Real Ed25519 signing over claim.toSignedCoreCbor() is blocked on Phase 4
      // identity/keypair work (lib/identity/). See CLAIM_SCHEMA.md §5 and PERSON_C.md Week 2 Day 1.
      await ClaimRepository().insertClaim(claim);

      if (!mounted) return;
      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Hazard report registered and saved for ${_hazardLabel(_hazardType)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          backgroundColor: AppColors.amberDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } catch (e, st) {
      debugPrint('[_ReportFormSheetState] _submitForm error: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Couldn\'t save — please try again',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          backgroundColor: AppColors.darkRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.amberLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.amberDark.withAlpha(80)),
                  ),
                  child: const Icon(
                    Icons.report_problem_outlined,
                    color: AppColors.amberDark,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Report Hazard',
                        style: TextStyle(
                          color: AppColors.primaryText,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Flag dangers to alert responders and community',
                        style: TextStyle(
                          color: AppColors.secondaryText,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
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

            const SizedBox(height: 20),

            // ─── Hazard Type Selector ───────────────────────────────
            const Text(
              'Select Hazard Kind',
              style: TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),

            // 2x2 Grid of Hazard Types
            Column(
              children: [
                Row(
                  children: [
                    _buildHazardOption(
                      type: HazardType.flood,
                      label: 'Flood',
                      icon: Icons.water_drop_outlined,
                    ),
                    const SizedBox(width: 10),
                    _buildHazardOption(
                      type: HazardType.roadBlock,
                      label: 'Road Block',
                      icon: Icons.block_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _buildHazardOption(
                      type: HazardType.structuralDamage,
                      label: 'Structural Damage',
                      icon: Icons.domain_disabled_outlined,
                    ),
                    const SizedBox(width: 10),
                    _buildHazardOption(
                      type: HazardType.other,
                      label: 'Other Hazard',
                      icon: Icons.warning_amber_rounded,
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 20),
            _buildLocationIndicator(),
            const SizedBox(height: 20),

            // ─── Optional Note Input ────────────────────────────────
            const Text(
              'Details / Note (Optional)',
              style: TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Add landmarks, severity, or alternate routes.',
              style: TextStyle(
                color: AppColors.secondaryText,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _noteController,
              maxLength: 80, // Enforce 80 char cap — CLAIM_SCHEMA.md §9.2
              maxLines: 2,
              style: const TextStyle(fontSize: 14, color: AppColors.primaryText),
              decoration: InputDecoration(
                hintText: 'e.g., Bridge impassable, water level 4ft and rising',
                hintStyle: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
                filled: true,
                fillColor: AppColors.creamBackground,
                counterStyle: const TextStyle(fontSize: 11, color: AppColors.secondaryText),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.borderSubtle),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.amberDark, width: 1.5),
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),

            const SizedBox(height: 24),

            // ─── Submit Button ──────────────────────────────────────
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.amberDark,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _submitForm,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.report_problem_outlined, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Submit Hazard Report',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationIndicator() {
    IconData icon;
    String text;
    Color color;
    bool isInteractive = false;

    switch (_locationStatus) {
      case LocationStatus.fetching:
        icon = Icons.location_searching;
        text = 'Acquiring GPS...';
        color = AppColors.secondaryText;
        break;
      case LocationStatus.success:
        icon = Icons.my_location;
        text = 'Using your current location';
        color = AppColors.darkGreen;
        break;
      case LocationStatus.manual:
        icon = Icons.pin_drop;
        text = 'Using pinned map location';
        color = AppColors.darkGreen;
        break;
      case LocationStatus.error:
        icon = Icons.location_off;
        text = 'GPS unavailable. Tap here to set location on map.';
        color = AppColors.darkRed;
        isInteractive = true;
        break;
    }

    Widget content = Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );

    if (isInteractive) {
      return GestureDetector(
        onTap: () => Navigator.pop(context, 'pick_location'),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.redLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.darkRed.withAlpha(50)),
          ),
          child: content,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.borderSubtle.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: content,
    );
  }

  Widget _buildHazardOption({
    required HazardType type,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _hazardType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _hazardType = type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.amberLight : AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppColors.amberDark : AppColors.borderSubtle,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected ? AppColors.amberDark : AppColors.secondaryText,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? AppColors.amberDark : AppColors.primaryText,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _hazardLabel(HazardType type) => switch (type) {
        HazardType.flood => 'Flood',
        HazardType.roadBlock => 'Road Block',
        HazardType.structuralDamage => 'Structural Damage',
        HazardType.other => 'Other Hazard',
      };
}
