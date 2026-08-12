import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

/// Full-screen camera scanner with a corner-bracket viewfinder. Pops with the
/// first decoded QR string.
///
/// This screen is dark in BOTH themes and does not read `context.ck`. A camera
/// preview needs a neutral dark frame to stay legible, and light chrome over a
/// live viewfinder washes it out, so the canvas is the fixed [scannerBg] and
/// every mark on it is white. That is a deliberate exception to the app's
/// theme-aware rule, not an oversight.
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final _controller = MobileScannerController();
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: scannerBg,
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(controller: _controller, onDetect: _onDetect),
          ),
          // Dim overlay for legibility, tinted to the brand's dark floor.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0x4015131A)),
            ),
          ),
          Center(
            child: SizedBox(
              width: 260,
              height: 260,
              child: CustomPaint(painter: _CornerBrackets()),
            ),
          ),
          SafeArea(
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Text(
                  'Scan pairing QR',
                  style: Ct.title(18, color: Colors.white),
                ),
              ],
            ),
          ),
          // Bottom chrome: the hint in a quiet chip, and a torch toggle,
          // pairing regularly happens in the evening next to a laptop screen,
          // and a QR in the dark is exactly when a torch earns its place.
          Positioned(
            left: 44,
            right: 44,
            bottom: 40,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<MobileScannerState>(
                    valueListenable: _controller,
                    builder: (context, state, _) {
                      if (state.torchState == TorchState.unavailable) {
                        return const SizedBox.shrink();
                      }
                      final on = state.torchState == TorchState.on;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Material(
                          color: on
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.14),
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: _controller.toggleTorch,
                            child: SizedBox(
                              width: 52,
                              height: 52,
                              child: Icon(
                                on
                                    ? Icons.flashlight_on_rounded
                                    : Icons.flashlight_off_rounded,
                                size: ClipIcons.nav,
                                color: on ? scannerBg : Colors.white,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Point at the QR shown on your other device.',
                      textAlign: TextAlign.center,
                      style: Ct.body(13.5, color: Colors.white),
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _CornerBrackets extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const r = 18.0; // corner radius
    const len = 50.0; // arm length
    final w = size.width, h = size.height;

    void corner(double cx, double cy, double dx, double dy) {
      final path = Path()
        ..moveTo(cx + dx * len, cy)
        ..lineTo(cx + dx * r, cy)
        ..arcToPoint(
          Offset(cx, cy + dy * r),
          radius: const Radius.circular(r),
          clockwise: dx * dy < 0,
        )
        ..lineTo(cx, cy + dy * len);
      canvas.drawPath(path, paint);
    }

    corner(0, 0, 1, 1); // top-left
    corner(w, 0, -1, 1); // top-right
    corner(w, h, -1, -1); // bottom-right
    corner(0, h, 1, -1); // bottom-left
  }

  @override
  bool shouldRepaint(_) => false;
}
