import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

/// Clippy design tokens — the warm editorial palette from the design mockups.
abstract class Ck {
  static const bg = Color(0xFFF4F1EA); // cream background
  static const surface = Color(0xFFFFFFFF); // white cards
  static const ink = Color(0xFF1E1C15); // primary text
  static const border = Color(0xFFE3DED2); // tan border / divider
  static const borderStrong = Color(0xFFCFC9BA); // outlined-button border
  static const muted = Color(0xFFA39C8B); // muted meta
  static const muted2 = Color(0xFF7A7466); // secondary text
  static const green = Color(0xFF1F4B3F); // deep-green accent
  static const rust = Color(0xFF9A4432); // reconnecting
  static const snack = Color(0xFF262319); // dark snackbar
  static const dialogBg = Color(0xFFFBFAF6);
  static const scannerBg = Color(0xFF161511);
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
