import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// Screen for generating and displaying the device's cryptographic identity
/// (public key and device ID) for volunteer campaign registration.
/// 
/// This screen handles local identity display only. NodeTrust vouching
/// and mesh broadcast happen in Phase 4.
class VolunteerIdentityScreen extends StatefulWidget {
  const VolunteerIdentityScreen({super.key});

  @override
  State<VolunteerIdentityScreen> createState() => _VolunteerIdentityScreenState();
}

class _VolunteerIdentityScreenState extends State<VolunteerIdentityScreen> {
  DeviceKeyPair? _keyPair;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final keyPair = await DeviceKeyPair.loadOrCreateProvisional();
    if (mounted) {
      setState(() {
        _keyPair = keyPair;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Volunteer Identity'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.badge_outlined,
                    size: 64,
                    color: AppColors.deepNavy,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Campaign Registration',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Have an organiser scan this code to vouch for your device and grant you volunteer permissions.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.secondaryText,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Placeholder for QR Code since qr_flutter is not in pubspec
                  Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      color: AppColors.creamBackground,
                      border: Border.all(color: AppColors.borderMedium, width: 2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.qr_code_2, size: 48, color: AppColors.borderMedium),
                        SizedBox(height: 8),
                        Text(
                          '[QR Code Placeholder]',
                          style: TextStyle(
                            color: AppColors.secondaryText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  _buildInfoRow('Device ID', _keyPair!.deviceId),
                  const SizedBox(height: 12),
                  _buildInfoRow(
                    'Public Key', 
                    base64Encode(_keyPair!.publicKey),
                    isMonospace: true,
                  ),

                  const SizedBox(height: 48),

                  // Warning about app uninstall
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.redLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.darkRed.withAlpha(100)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: AppColors.darkRed, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                'Identity is tied to this device',
                                style: TextStyle(
                                  color: AppColors.darkRed,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Your cryptographic identity and volunteer status will be permanently lost if you uninstall the app or clear its data. There is no cloud backup.',
                                style: TextStyle(
                                  color: AppColors.darkRed,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ],
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

  Widget _buildInfoRow(String label, String value, {bool isMonospace = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.secondaryText,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontFamily: isMonospace ? 'monospace' : null,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryText,
            ),
          ),
        ),
      ],
    );
  }
}
