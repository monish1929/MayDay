import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mayday/common/device_id.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Type selector choices for Rescue form — PERSON_C.md §3 Day 3.
enum RescueType { individual, group, proxy }

/// Bottom sheet form for requesting Rescue (SOS / Proxy SOS).
///
/// Features:
/// - Type selector: Individual / Group / Proxy
/// - Headcount bucket selector: only shown/required for Group, optional for Proxy, none for Individual
/// - Proxy note: optional text field capped at 80 chars (for Proxy only)
/// - On submit: constructs SosPayload or SosProxyPayload and prints to console
class RescueFormSheet extends StatefulWidget {
  final GeoPoint? initialLocation;

  const RescueFormSheet({
    super.key,
    this.initialLocation,
  });

  static Future<dynamic> show(BuildContext context, {GeoPoint? location}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => RescueFormSheet(
        initialLocation: location,
      ),
    );
  }

  @override
  State<RescueFormSheet> createState() => _RescueFormSheetState();
}

enum LocationStatus { fetching, success, error, manual }

class _RescueFormSheetState extends State<RescueFormSheet> {
  RescueType _rescueType = RescueType.individual;
  HeadcountBucket? _headcountBucket;
  final TextEditingController _proxyNoteController = TextEditingController();

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
      debugPrint('[RescueFormSheet] Location fetch failed: $e');
      if (!mounted) return;
      setState(() => _locationStatus = LocationStatus.error);
    }
  }

  @override
  void dispose() {
    _proxyNoteController.dispose();
    super.dispose();
  }

  void _onRescueTypeChanged(RescueType type) {
    setState(() {
      _rescueType = type;
      if (type == RescueType.individual) {
        _headcountBucket = null;
      } else if (type == RescueType.group && _headcountBucket == null) {
        _headcountBucket = HeadcountBucket.twoToFive;
      }
    });
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
        debugPrint('[RescueFormSheet] WARNING: Using placeholder Bengaluru location as absolute last resort!');
        location = const GeoPoint(lat: 12.9716, lon: 77.5946);
      }

      final deviceId = await LocalDeviceId.getDeviceId();
      ClaimPayload payload;

      switch (_rescueType) {
        case RescueType.individual:
          payload = SosPayload(
            location: location,
            headcount: null,
          );
          break;
        case RescueType.group:
          payload = SosPayload(
            location: location,
            headcount: _headcountBucket ?? HeadcountBucket.twoToFive,
          );
          break;
        case RescueType.proxy:
          final rawNote = _proxyNoteController.text.trim();
          final note = rawNote.isEmpty ? null : rawNote;
          payload = SosProxyPayload(
            location: location,
            reporterDeviceId: deviceId,
            headcount: _headcountBucket,
            proxyNote: note,
          );
          break;
      }

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
            _rescueType == RescueType.proxy
                ? 'Proxy SOS recorded. It will reach nearby phones as they come into range.'
                : 'Rescue SOS recorded. It will reach nearby phones as they come into range.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          backgroundColor: AppColors.darkRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } catch (e, st) {
      debugPrint('[_RescueFormSheetState] _submitForm error: $e\n$st');
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
                    color: AppColors.redLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.darkRed.withAlpha(80)),
                  ),
                  child: const Icon(
                    Icons.sos_rounded,
                    color: AppColors.darkRed,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Request Rescue',
                        style: TextStyle(
                          color: AppColors.primaryText,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Raise an emergency SOS — it reaches nearby phones over time as they come into range',
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
            _buildLocationIndicator(),
            const SizedBox(height: 20),

            // ─── Rescue Type Selection ──────────────────────────────
            const Text(
              'Who needs rescue?',
              style: TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _buildTypeCard(
                  type: RescueType.individual,
                  title: 'Individual',
                  icon: Icons.person_outline,
                ),
                const SizedBox(width: 8),
                _buildTypeCard(
                  type: RescueType.group,
                  title: 'Group',
                  icon: Icons.groups_outlined,
                ),
                const SizedBox(width: 8),
                _buildTypeCard(
                  type: RescueType.proxy,
                  title: 'Proxy',
                  subtitle: 'For another',
                  icon: Icons.person_pin_circle_outlined,
                ),
              ],
            ),

            // ─── Headcount Bucket Selector ──────────────────────────
            if (_rescueType == RescueType.group || _rescueType == RescueType.proxy) ...[
              const SizedBox(height: 20),
              Text(
                _rescueType == RescueType.group
                    ? 'Estimated Headcount (Required)'
                    : 'Estimated Headcount (Optional)',
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _buildHeadcountChip(
                    bucket: HeadcountBucket.twoToFive,
                    label: '2 – 5 people',
                  ),
                  const SizedBox(width: 8),
                  _buildHeadcountChip(
                    bucket: HeadcountBucket.sixToFifteen,
                    label: '6 – 15 people',
                  ),
                  const SizedBox(width: 8),
                  _buildHeadcountChip(
                    bucket: HeadcountBucket.fifteenPlus,
                    label: '15+ people',
                  ),
                ],
              ),
            ],

            // ─── Proxy Note Input ───────────────────────────────────
            if (_rescueType == RescueType.proxy) ...[
              const SizedBox(height: 20),
              const Text(
                'Proxy Note (Optional)',
                style: TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Describe location or special needs for who you are reporting for.',
                style: TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _proxyNoteController,
                maxLength: 80, // Enforce 80 char cap — CLAIM_SCHEMA.md §9.2
                maxLines: 2,
                style: const TextStyle(fontSize: 14, color: AppColors.primaryText),
                decoration: InputDecoration(
                  hintText: 'e.g., Trapped on 1st floor of red house, elderly woman',
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
                    borderSide: const BorderSide(color: AppColors.darkRed, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ─── Submit Button ──────────────────────────────────────
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.darkRed,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _submitForm,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.sos_rounded, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    _rescueType == RescueType.proxy
                        ? 'Send Proxy SOS'
                        : 'Send Rescue SOS',
                    style: const TextStyle(
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

  Widget _buildTypeCard({
    required RescueType type,
    required String title,
    String? subtitle,
    required IconData icon,
  }) {
    final isSelected = _rescueType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => _onRescueTypeChanged(type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.redLight : AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppColors.darkRed : AppColors.borderSubtle,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                color: isSelected ? AppColors.darkRed : AppColors.secondaryText,
                size: 24,
              ),
              const SizedBox(height: 6),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isSelected ? AppColors.darkRed : AppColors.primaryText,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isSelected
                        ? AppColors.darkRed.withAlpha(200)
                        : AppColors.secondaryText,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeadcountChip({
    required HeadcountBucket bucket,
    required String label,
  }) {
    final isSelected = _headcountBucket == bucket;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            if (_rescueType == RescueType.proxy && _headcountBucket == bucket) {
              _headcountBucket = null; // allow deselection for proxy
            } else {
              _headcountBucket = bucket;
            }
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.redLight : AppColors.creamBackground,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? AppColors.darkRed : AppColors.borderSubtle,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? AppColors.darkRed : AppColors.primaryText,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
