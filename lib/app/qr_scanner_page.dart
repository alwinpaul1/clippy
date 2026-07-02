import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

/// Full-screen camera scanner (dark, corner-bracket viewfinder — matches the
/// design mockup). Pops with the first decoded QR string.
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
      backgroundColor: Ck.scannerBg,
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(controller: _controller, onDetect: _onDetect),
          ),
          // Dim overlay for legibility.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0x40161511)),
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
                  icon: const Icon(Icons.arrow_back, color: Ck.bg),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Text(
                  'Scan pairing QR',
                  style: Ct.body(18, weight: FontWeight.w500, color: Ck.bg),
                ),
              ],
            ),
          ),
          Positioned(
            left: 44,
            right: 44,
            bottom: 56,
            child: Text(
              'Point at the QR shown on your other device.',
              textAlign: TextAlign.center,
              style: Ct.body(14, color: const Color(0xBFF4F1EA)),
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
      ..color = Ck.bg
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
