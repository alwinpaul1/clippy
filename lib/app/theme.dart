import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

/// Clippy design tokens — the warm editorial palette from the design mockups.
/// These are the *light* constants; screens that switch with the theme read
/// [ClippyColors] from context instead (see [ClippyColorsX]).
abstract class Ck {
  static const bg = Color(0xFFF4F1EA); // cream background
  static const surface = Color(0xFFFFFFFF); // white cards
  static const ink = Color(0xFF1E1C15); // primary text
  static const border = Color(0xFFE3DED2); // tan border / divider
  static const borderStrong = Color(0xFFCFC9BA); // outlined-button border
  static const muted = Color(0xFFA39C8B); // muted meta
  static const muted2 = Color(0xFF7A7466); // secondary text
  static const green = Color(0xFF1F4B3F); // deep-green accent
  static const rust = Color(0xFF9A4432); // reconnecting / destructive
  static const snack = Color(0xFF262319); // dark snackbar
  static const dialogBg = Color(0xFFFBFAF6);
  static const scannerBg = Color(0xFF161511);
  static const selBg = Color(0xFFF1F5F2); // selected-row tint
}

/// Theme-aware palette (light + warm-ink dark). Registered on ThemeData and
/// read via `context.ck` so the same widgets render in either mode.
@immutable
class ClippyColors extends ThemeExtension<ClippyColors> {
  final Color bg, surface, ink, border, borderStrong;
  final Color muted, muted2, green, rust, snack, dialogBg, selBg;
  final bool isDark;

  const ClippyColors({
    required this.bg,
    required this.surface,
    required this.ink,
    required this.border,
    required this.borderStrong,
    required this.muted,
    required this.muted2,
    required this.green,
    required this.rust,
    required this.snack,
    required this.dialogBg,
    required this.selBg,
    required this.isDark,
  });

  static const light = ClippyColors(
    bg: Ck.bg,
    surface: Ck.surface,
    ink: Ck.ink,
    border: Ck.border,
    borderStrong: Ck.borderStrong,
    muted: Ck.muted,
    muted2: Ck.muted2,
    green: Ck.green,
    rust: Ck.rust,
    snack: Ck.snack,
    dialogBg: Ck.dialogBg,
    selBg: Ck.selBg,
    isDark: false,
  );

  // Warm-ink dark palette from mockup 3b.
  static const dark = ClippyColors(
    bg: Color(0xFF181712),
    surface: Color(0xFF211F18),
    ink: Color(0xFFF0EDE4),
    border: Color(0xFF2E2C23),
    borderStrong: Color(0xFF3A3730),
    muted: Color(0xFF6E6857),
    muted2: Color(0xFFA8A292),
    green: Color(0xFF8FBCA6), // lighter green reads on dark
    rust: Color(0xFFCF7A68),
    snack: Color(0xFF2E2B22),
    dialogBg: Color(0xFF211F18),
    selBg: Color(0xFF20291F),
    isDark: true,
  );

  /// Hex (no '#') for the mascot SVG, which takes string colors.
  String hex(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2);

  @override
  ClippyColors copyWith() => this;

  @override
  ClippyColors lerp(ThemeExtension<ClippyColors>? other, double t) {
    if (other is! ClippyColors) return this;
    return t < 0.5 ? this : other;
  }
}

extension ClippyColorsX on BuildContext {
  ClippyColors get ck =>
      Theme.of(this).extension<ClippyColors>() ?? ClippyColors.light;
}

/// Text-style helpers using the mockup's fonts (fetched via google_fonts).
abstract class Ct {
  static TextStyle title(double size, {Color color = Ck.ink}) =>
      GoogleFonts.newsreader(
        fontSize: size,
        fontWeight: FontWeight.w500,
        color: color,
        letterSpacing: -0.01 * size,
        height: 1.18,
      );

  static TextStyle body(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color color = Ck.ink,
    double height = 1.4,
  }) => GoogleFonts.instrumentSans(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
  );

  static TextStyle mono(
    double size, {
    Color color = Ck.muted,
    FontWeight weight = FontWeight.w400,
  }) => GoogleFonts.ibmPlexMono(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: 1.35,
  );

  static TextStyle sectionLabel() => GoogleFonts.instrumentSans(
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.5,
    color: Ck.muted,
  );
}

/// The Clippy paperclip-with-eyes mark (the exact SVG from the mockups),
/// recolorable for the app bar (ink), pairing (green), and empty state (faded).
class ClippyMark extends StatelessWidget {
  final double height;
  final String clipHex;
  final String eyeHex;
  final String eyeFill;

  const ClippyMark({
    super.key,
    this.height = 24,
    this.clipHex = '1E1C15',
    this.eyeHex = '1E1C15',
    this.eyeFill = 'ffffff',
  });

  @override
  Widget build(BuildContext context) {
    final svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 84">'
        '<path d="M18,24 V58 A12,12 0 0 0 42,58 V18 A8,8 0 0 0 26,18 V56 A4,4 0 0 0 34,56 V26" '
        'fill="none" stroke="#$clipHex" stroke-width="7" stroke-linecap="round"/>'
        '<circle cx="24" cy="8" r="6.5" fill="#$eyeFill" stroke="#$eyeHex" stroke-width="2"/>'
        '<circle cx="38" cy="8" r="6.5" fill="#$eyeFill" stroke="#$eyeHex" stroke-width="2"/>'
        '<circle cx="25.5" cy="9" r="3" fill="#$eyeHex"/>'
        '<circle cx="39.5" cy="9" r="3" fill="#$eyeHex"/>'
        '</svg>';
    return SvgPicture.string(svg, height: height, width: height * 60 / 84);
  }
}

/// The Clippy mark, alive: it bobs gently and blinks (mockup turn 3). Used in
/// the app header; the static [ClippyMark] stays for pairing / empty states.
class AnimatedClippyMark extends StatefulWidget {
  final double height;
  final String clipHex;
  final String eyeHex;
  final String eyeFill;

  const AnimatedClippyMark({
    super.key,
    this.height = 24,
    this.clipHex = '1E1C15',
    this.eyeHex = '1E1C15',
    this.eyeFill = 'ffffff',
  });

  @override
  State<AnimatedClippyMark> createState() => _AnimatedClippyMarkState();
}

class _AnimatedClippyMarkState extends State<AnimatedClippyMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 5500),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String get _base =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 84">'
      '<path d="M18,24 V58 A12,12 0 0 0 42,58 V18 A8,8 0 0 0 26,18 V56 A4,4 0 0 0 34,56 V26" '
      'fill="none" stroke="#${widget.clipHex}" stroke-width="7" stroke-linecap="round"/>'
      '<circle cx="24" cy="8" r="6.5" fill="#${widget.eyeFill}" stroke="#${widget.eyeHex}" stroke-width="2"/>'
      '<circle cx="38" cy="8" r="6.5" fill="#${widget.eyeFill}" stroke="#${widget.eyeHex}" stroke-width="2"/>'
      '</svg>';

  String get _pupils =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 84">'
      '<circle cx="25.5" cy="9" r="3" fill="#${widget.eyeHex}"/>'
      '<circle cx="39.5" cy="9" r="3" fill="#${widget.eyeHex}"/>'
      '</svg>';

  @override
  Widget build(BuildContext context) {
    final w = widget.height * 60 / 84;
    final h = widget.height;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        // Gentle bob + sway, pivoting near the base of the clip.
        final bob = math.sin(t * 2 * math.pi) * (h * 0.055);
        final sway = math.sin(t * 2 * math.pi) * 0.05;
        // Blink a couple of times per loop (~every 2.7s) so Clippy feels alive
        // without being twitchy. Each blink is a quick dip in eye height.
        double blinkAt(double centre) {
          final d = (t - centre).abs();
          return d < 0.035 ? d / 0.035 : 1.0;
        }
        final blink = math.min(blinkAt(0.32), blinkAt(0.78));
        return Transform.translate(
          offset: Offset(0, bob),
          child: Transform.rotate(
            angle: sway,
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                children: [
                  SvgPicture.string(_base, height: h, width: w),
                  // Pupils blink: scale their eye-line vertically to ~0.
                  Transform(
                    alignment: const Alignment(0, -0.79), // eye line (cy≈9/84)
                    transform: Matrix4.diagonal3Values(1, blink, 1),
                    child: SvgPicture.string(_pupils, height: h, width: w),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
