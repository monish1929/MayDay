import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mayday/ui/theme/app_theme.dart';

/// QR scanner screen skeleton — PERSON_C.md §3 Day 5.
///
/// Viewfinder and camera permission handling only.
/// Signature verification, QR decoding, and claim resolution logic lands
/// in Phase 3 per CLAIM_SCHEMA.md §6.2 — no verification logic here.
class QRScannerScreen extends StatefulWidget {
  static const routeName = '/qr-scanner';

  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  late final MobileScannerController _scannerController;
  bool _isTorchOn = false;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Row(
          children: [
            Icon(Icons.qr_code_scanner, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text(
              'QR Scanner',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isTorchOn ? Icons.flash_on : Icons.flash_off,
              color: Colors.white,
            ),
            tooltip: 'Toggle Flash',
            onPressed: () async {
              await _scannerController.toggleTorch();
              if (mounted) {
                setState(() {
                  _isTorchOn = !_isTorchOn;
                });
              }
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ─── Camera Viewfinder ─────────────────────────────────────
          MobileScanner(
            controller: _scannerController,
            errorBuilder: (context, error) {
              return _buildCameraErrorView(context, error);
            },
            onDetect: (capture) {
              // Phase 3 scope per CLAIM_SCHEMA.md §6.2:
              // No signature verification, decoding, or resolution logic yet.
              debugPrint('[QRScanner] Barcode detected: ${capture.barcodes.length} (Resolution in Phase 3)');
            },
          ),

          // ─── Custom Viewfinder Reticle Overlay ─────────────────────
          _buildViewfinderOverlay(context),

          // ─── Phase 3 Scope Notice Banner ──────────────────────────
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.deepNavy.withAlpha(230),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withAlpha(40),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(60),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: AppColors.amberYellow, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Viewfinder skeleton (Day 5). QR signature verification & claim resolution logic lands in Phase 3.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Custom scanning reticle frame overlay.
  Widget _buildViewfinderOverlay(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final scanBoxSize = size.width * 0.70;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Semi-transparent cutout container
        Container(
          width: scanBoxSize,
          height: scanBoxSize,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withAlpha(180), width: 2),
            borderRadius: BorderRadius.circular(20),
          ),
        ),

        // 4 Corner accents
        SizedBox(
          width: scanBoxSize + 8,
          height: scanBoxSize + 8,
          child: Stack(
            children: [
              // Top-left
              Positioned(
                top: 0,
                left: 0,
                child: _buildCorner(isTop: true, isLeft: true),
              ),
              // Top-right
              Positioned(
                top: 0,
                right: 0,
                child: _buildCorner(isTop: true, isLeft: false),
              ),
              // Bottom-left
              Positioned(
                bottom: 0,
                left: 0,
                child: _buildCorner(isTop: false, isLeft: true),
              ),
              // Bottom-right
              Positioned(
                bottom: 0,
                right: 0,
                child: _buildCorner(isTop: false, isLeft: false),
              ),
            ],
          ),
        ),

        // Helper text directly above the scan reticle
        Positioned(
          top: (size.height - scanBoxSize) / 2 - 48,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(140),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'Align QR code within the frame',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCorner({required bool isTop, required bool isLeft}) {
    const length = 24.0;
    const thickness = 4.0;
    const color = AppColors.strongBlue;

    return SizedBox(
      width: length,
      height: length,
      child: CustomPaint(
        painter: _CornerPainter(
          isTop: isTop,
          isLeft: isLeft,
          thickness: thickness,
          color: color,
        ),
      ),
    );
  }

  /// Graceful error screen when camera permission is denied or camera fails.
  Widget _buildCameraErrorView(
    BuildContext context,
    MobileScannerException error,
  ) {
    final isPermission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28.0),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(40),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: AppColors.redLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.videocam_off_outlined,
                  size: 40,
                  color: AppColors.darkRed,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isPermission
                    ? 'Camera Permission Required'
                    : 'Camera Initialization Error',
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isPermission
                    ? 'Camera access is needed to scan verification QR codes on survivor or volunteer devices.'
                    : 'Unable to start camera sensor (${error.errorCode.name}).',
                style: const TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 13,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () {
                  _scannerController.start();
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.deepNavy,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final bool isTop;
  final bool isLeft;
  final double thickness;
  final Color color;

  _CornerPainter({
    required this.isTop,
    required this.isLeft,
    required this.thickness,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    if (isTop && isLeft) {
      path.moveTo(0, size.height);
      path.lineTo(0, 0);
      path.lineTo(size.width, 0);
    } else if (isTop && !isLeft) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height);
    } else if (!isTop && isLeft) {
      path.moveTo(0, 0);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(0, size.height);
      path.lineTo(size.width, size.height);
      path.lineTo(size.width, 0);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
