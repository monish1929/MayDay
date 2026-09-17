import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mayday/ui/models/models.dart';
import 'package:mayday/ui/theme/app_theme.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/signature.dart';

/// Screen for a requester to display a QR code to a volunteer.
/// 
/// The QR code allows a volunteer to counter-sign the SOS, verifying that
/// they have made physical contact with the requester.
/// CLAIM_SCHEMA.md §6.2 Phase 3 scope.
class SosQrDisplayScreen extends StatefulWidget {
  final Claim claim;

  const SosQrDisplayScreen({
    super.key,
    required this.claim,
  });

  @override
  State<SosQrDisplayScreen> createState() => _SosQrDisplayScreenState();
}

class _SosQrDisplayScreenState extends State<SosQrDisplayScreen> {
  bool _isLoading = true;
  String? _qrPayload;

  @override
  void initState() {
    super.initState();
    _generateSignedPayload();
  }

  /// Generates a fresh nonce, signs the combination of sosId and nonce,
  /// and formats them into a single payload string for the QR code.
  Future<void> _generateSignedPayload() async {
    try {
      // 1. Generate a fresh 16-byte secure random nonce.
      // CLAIM_SCHEMA.md requires this to regenerate each time the QR is shown
      // to prevent replay attacks.
      final random = Random.secure();
      final nonceBytes = List<int>.generate(16, (_) => random.nextInt(256));
      final nonce = base64UrlEncode(nonceBytes);

      // 2. Load the device's cryptographic identity
      final keyPair = await DeviceKeyPair.loadOrCreateProvisional();

      // 3. Sign the message: "sosId:nonce"
      // We use a simple delimited format that the scanner can easily parse.
      final messageString = '${widget.claim.id}:$nonce';
      final messageBytes = utf8.encode(messageString);
      
      final signatureBytes = await ClaimSignature.sign(messageBytes, keyPair);
      final signature = base64UrlEncode(signatureBytes);

      // 4. Construct the final QR payload.
      // Format chosen: JSON for unambiguous parsing on the volunteer side.
      final payloadMap = {
        'sosId': widget.claim.id,
        'nonce': nonce,
        'sig': signature,
      };

      if (mounted) {
        setState(() {
          _qrPayload = jsonEncode(payloadMap);
          _isLoading = false;
        });
      }
    } catch (e) {
      // In a production app, we would handle this with a user-facing error.
      debugPrint('Failed to generate signed QR payload: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: const Text('Verify Identity'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.verified_user_outlined,
                      size: 56,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Have a volunteer scan this code',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'This proves you are the original requester of the SOS.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 48),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(50),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: QrImageView(
                        data: _qrPayload!,
                        version: QrVersions.auto,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                        backgroundColor: Colors.white,
                        size: 240,
                      ),
                    ),
                    const SizedBox(height: 48),
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _isLoading = true;
                        });
                        _generateSignedPayload();
                      },
                      icon: const Icon(Icons.refresh, color: Colors.white70),
                      label: const Text(
                        'Generate New Code',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
