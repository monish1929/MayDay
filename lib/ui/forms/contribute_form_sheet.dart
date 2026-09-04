import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mayday/common/device_id.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Bottom sheet form for contributing/pledging resources — PERSON_C.md §3 Day 3, CLAIM_SCHEMA.md §8 + §8.1.
///
/// Gated to verified volunteers only (handled in main_screen.dart caller).
///
/// Features:
/// - Category selector: foodWater | shelter | medical | equipment (canonical four)
/// - Pledged count: numeric input (volunteer-written authoritative count)
/// - On submit: constructs ResourcePayload, creates Claim via ClaimFactory, and persists via ClaimRepository
class ContributeFormSheet extends StatefulWidget {
  final GeoPoint initialLocation;

  const ContributeFormSheet({
    super.key,
    this.initialLocation = const GeoPoint(lat: 12.9716, lon: 77.5946),
  });

  static Future<void> show(BuildContext context, {GeoPoint? location}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ContributeFormSheet(
        initialLocation: location ?? const GeoPoint(lat: 12.9716, lon: 77.5946),
      ),
    );
  }

  @override
  State<ContributeFormSheet> createState() => _ContributeFormSheetState();
}

class _ContributeFormSheetState extends State<ContributeFormSheet> {
  ResourceCategory _category = ResourceCategory.foodWater;
  final TextEditingController _countController = TextEditingController(text: '10');

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  int get _parsedCount {
    final val = int.tryParse(_countController.text);
    return (val == null || val <= 0) ? 1 : val;
  }

  void _adjustCount(int delta) {
    final current = int.tryParse(_countController.text) ?? 0;
    final next = (current + delta).clamp(1, 99999);
    setState(() {
      _countController.text = next.toString();
    });
  }

  Future<void> _submitForm() async {
    final count = _parsedCount;
    final deviceId = await LocalDeviceId.getDeviceId();

    final payload = ResourcePayload(
      location: widget.initialLocation,
      category: _category,
      pledgedCount: count,
      claimedReports: 0,
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
          'Pledged and registered $count units of ${_categoryLabel(_category)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.darkGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
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
                    color: AppColors.greenLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.darkGreen.withAlpha(80)),
                  ),
                  child: const Icon(
                    Icons.volunteer_activism_outlined,
                    color: AppColors.darkGreen,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Contribute Resource',
                        style: TextStyle(
                          color: AppColors.primaryText,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Volunteer registered supply point',
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

            // ─── Resource Category Selector (Canonical 4) ───────────
            const Text(
              'Resource Category',
              style: TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),

            // 2x2 Grid of canonical categories
            Column(
              children: [
                Row(
                  children: [
                    _buildCategoryOption(
                      category: ResourceCategory.foodWater,
                      label: 'Food & Water',
                      icon: Icons.restaurant,
                    ),
                    const SizedBox(width: 10),
                    _buildCategoryOption(
                      category: ResourceCategory.shelter,
                      label: 'Shelter',
                      icon: Icons.home_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _buildCategoryOption(
                      category: ResourceCategory.medical,
                      label: 'Medical',
                      icon: Icons.medical_services_outlined,
                    ),
                    const SizedBox(width: 10),
                    _buildCategoryOption(
                      category: ResourceCategory.equipment,
                      label: 'Equipment',
                      icon: Icons.build_outlined,
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ─── Pledged Count Input ────────────────────────────────
            const Text(
              'Pledged Quantity (Units / Packets)',
              style: TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Authoritative count verified by volunteer.',
              style: TextStyle(
                color: AppColors.secondaryText,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                // Decrement button
                _buildStepButton(
                  icon: Icons.remove,
                  onPressed: () => _adjustCount(-5),
                ),
                const SizedBox(width: 8),

                // Text field
                Expanded(
                  child: TextField(
                    controller: _countController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryText,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.creamBackground,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.borderSubtle),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.darkGreen, width: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Increment button
                _buildStepButton(
                  icon: Icons.add,
                  onPressed: () => _adjustCount(5),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Quick preset chips
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildPresetChip('+5', 5),
                _buildPresetChip('+10', 10),
                _buildPresetChip('+25', 25),
                _buildPresetChip('+50', 50),
                _buildPresetChip('+100', 100),
              ],
            ),

            const SizedBox(height: 24),

            // ─── Submit Button ──────────────────────────────────────
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.darkGreen,
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
                  Icon(Icons.inventory_2_outlined, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Pledge Resource',
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

  Widget _buildCategoryOption({
    required ResourceCategory category,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _category == category;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _category = category),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.greenLight : AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppColors.darkGreen : AppColors.borderSubtle,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected ? AppColors.darkGreen : AppColors.secondaryText,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? AppColors.darkGreen : AppColors.primaryText,
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

  Widget _buildStepButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.creamBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: IconButton(
        icon: Icon(icon, color: AppColors.deepNavy, size: 20),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildPresetChip(String label, int delta) {
    return GestureDetector(
      onTap: () => _adjustCount(delta),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.creamBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.primaryText,
          ),
        ),
      ),
    );
  }

  static String _categoryLabel(ResourceCategory category) => switch (category) {
        ResourceCategory.foodWater => 'Food & Water',
        ResourceCategory.shelter => 'Shelter',
        ResourceCategory.medical => 'Medical Supplies',
        ResourceCategory.equipment => 'Equipment',
      };
}
