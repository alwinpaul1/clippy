import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Clippy's design system: PAPER AND GRAPHITE WITH ONE SIGNAL ORANGE.
///
/// Rebuilt 2026-10-18 at the owner's request ("new palette, see Mobbin for
/// inspiration"), replacing the violet palette Clippy used to share with
/// Walletify. References: Polestar (graphite + a single vivid orange), Wabi
/// (soft off-white canvas, ink controls), Notion / Oura (calm charcoal dark).
///
/// The rules:
///  - The canvas is warm paper (light) or graphite (dark); cards sit one step
///    off it. Content is the colour; chrome stays neutral.
///  - PRIMARY IS INK. Filled buttons are near-black on paper and near-white on
///    graphite, the way a clipboard tool should look: quiet, legible, sure.
///  - ORANGE IS A SIGNAL, never a surface: selection, the copy confirmation,
///    the pairing moment, the update hero. If orange is everywhere it stops
///    meaning "look here".
///  - The sync light stays GREEN / RED. A state light in the brand colour
///    reads as decoration; green/red needs no legend.
///
/// Every pair is gated by `scripts/check_contrast.py` (run it after touching
/// any colour): body text >= 4.5:1, controls >= 3:1, in BOTH themes, on every
/// surface tier. Dark is hand-built, not seeded; a seeded dark scheme muddies
/// every accent.

/// Instrument Sans, bundled (see `assets/fonts/` and `pubspec.yaml`). It is
/// the app face AND the wordmark.
const appFontFamily = 'InstrumentSans';

/// The signal orange, as a FILL (and the gradient's light end). White text on
/// it measures 5.18:1.
const signalOrange = Color(0xFFC2410C);

/// The orange as a non-text mark (dots, outlines, the selected edge): brighter
/// than [signalOrange], which is tuned to carry white text.
const signalOrangeBright = Color(0xFFFF5A1F);

/// The gradient's dark end.
const signalOrangeDeep = Color(0xFFA8360A);

/// The one gradient. It marks MOMENTS (the update hero), never surfaces. Both
/// ends carry white text at >= 5.18:1.
const brandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [signalOrange, signalOrangeDeep],
);

/// The QR scanner's canvas. Fixed in both themes: a camera preview needs a
/// neutral dark frame, and a light scanner chrome washes the viewfinder out.
const scannerBg = Color(0xFF0F0F0E);

/// The sync status light. GREEN, deliberately not the brand orange, see the
/// rules above.
const syncOkLight = Color(0xFF0B7A45);
const syncOkDark = Color(0xFF4CCE8A);

/// Signal orange as TEXT/ICON ink, per theme (5.72:1 on a light card, 6.74:1
/// on a dark one).
const _accentTextLight = Color(0xFFB93A0A);
const _accentTextDark = Color(0xFFFF7A45);

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF161614),
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFE3E2DC),
  onPrimaryContainer: Color(0xFF161614),
  secondary: signalOrange,
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFFFFE4D6),
  onSecondaryContainer: Color(0xFF6A1F02),
  tertiary: Color(0xFF1D5FD0),
  onTertiary: Colors.white,
  tertiaryContainer: Color(0xFFDCE7FF),
  onTertiaryContainer: Color(0xFF0B2A66),
  error: Color(0xFFC4291C),
  onError: Colors.white,
  errorContainer: Color(0xFFFFDAD5),
  onErrorContainer: Color(0xFF7A0F06),
  surface: Color(0xFFF5F4F0),
  onSurface: Color(0xFF161614),
  onSurfaceVariant: Color(0xFF55534E),
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Color(0xFFEFEEEA),
  surfaceContainer: Color(0xFFE9E8E3),
  surfaceContainerHigh: Color(0xFFE3E2DC),
  surfaceContainerHighest: Color(0xFFDCDBD5),
  outline: Color(0xFF615F59),
  outlineVariant: Color(0xFFE2E0DA),
  inverseSurface: Color(0xFF242320),
  onInverseSurface: Color(0xFFF5F4F0),
  inversePrimary: Color(0xFFF3F2EE),
  shadow: Colors.black,
  scrim: Colors.black,
  surfaceTint: Colors.transparent,
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFF3F2EE),
  onPrimary: Color(0xFF161614),
  primaryContainer: Color(0xFF302F2C),
  onPrimaryContainer: Color(0xFFF3F2EE),
  secondary: Color(0xFFFF7A45),
  onSecondary: Color(0xFF2A0D00),
  secondaryContainer: Color(0xFF4A1E0A),
  onSecondaryContainer: Color(0xFFFFDCCB),
  tertiary: Color(0xFF7DA8FF),
  onTertiary: Color(0xFF0B2A66),
  tertiaryContainer: Color(0xFF173A7A),
  onTertiaryContainer: Color(0xFFDCE7FF),
  error: Color(0xFFFF8A7A),
  onError: Color(0xFF3A0A05),
  errorContainer: Color(0xFF7A0F06),
  onErrorContainer: Color(0xFFFFDAD5),
  surface: Color(0xFF0F0F0E),
  onSurface: Color(0xFFF3F2EE),
  onSurfaceVariant: Color(0xFFABA9A2),
  surfaceContainerLowest: Color(0xFF1A1A18),
  surfaceContainerLow: Color(0xFF161615),
  surfaceContainer: Color(0xFF20201E),
  surfaceContainerHigh: Color(0xFF282826),
  surfaceContainerHighest: Color(0xFF302F2C),
  outline: Color(0xFF9A9893),
  outlineVariant: Color(0xFF2E2D2A),
  inverseSurface: Color(0xFFF3F2EE),
  onInverseSurface: Color(0xFF1A1A18),
  inversePrimary: Color(0xFF161614),
  shadow: Colors.black,
  scrim: Colors.black,
  surfaceTint: Colors.transparent,
);

/// Theme-aware palette, DERIVED from the scheme above rather than hand-listed.
/// It survives from the old warm-editorial theme because ~50 call sites read
/// it through `context.ck`, and because a few of Clippy's roles (the snackbar
/// pair, the selected-row tint, the ink that sits on the brand gradient) have
/// no single M3 role to point at. Everything that DOES map to a role is that
/// role, so the two apps cannot drift apart.
@immutable
class ClippyColors extends ThemeExtension<ClippyColors> {
  /// Page canvas, `surface`.
  final Color bg;

  /// Card fill, `surfaceContainerLowest`.
  final Color surface;

  /// Primary text, `onSurface`.
  final Color ink;

  /// Hairline divider, `outlineVariant`.
  final Color border;

  /// Control outline, `outline`.
  final Color borderStrong;

  /// Weakest meta text. `outline`, which the audit put past 4.5:1 on every
  /// surface tier in both themes, so unlike the old palette it is safe for
  /// real sentences and not only for decoration.
  final Color muted;

  /// Secondary text, `onSurfaceVariant`.
  final Color muted2;

  /// Signal orange as INK (text and icons), tuned per theme for >= 4.5:1.
  final Color accent;

  /// Destructive / failing, `error`.
  final Color rust;

  /// The healthy sync light. See [syncOkLight].
  final Color syncOk;

  /// Snackbar chip and its label, `inverseSurface` / `onInverseSurface`.
  /// The old theme hardcoded a cream label because its chip was dark in BOTH
  /// themes. M3's inverse pair flips with the theme, so the label has to flip
  /// with it; that is why [onSnack] exists at all.
  final Color snack;
  final Color onSnack;

  /// Ink on [brandGradient]. White in both themes, because the gradient is
  /// the same orange in both (white clears 5.18:1 on [signalOrange]). Not
  /// `onPrimary`: that flips to dark ink in the dark theme.
  final Color onBrand;

  final Color dialogBg;

  /// Selected-row tint, the brand at low alpha, per theme.
  final Color selBg;

  final bool isDark;

  const ClippyColors({
    required this.bg,
    required this.surface,
    required this.ink,
    required this.border,
    required this.borderStrong,
    required this.muted,
    required this.muted2,
    required this.accent,
    required this.rust,
    required this.syncOk,
    required this.snack,
    required this.onSnack,
    required this.onBrand,
    required this.dialogBg,
    required this.selBg,
    required this.isDark,
  });

  factory ClippyColors.of(ColorScheme s) {
    final dark = s.brightness == Brightness.dark;
    return ClippyColors(
      bg: s.surface,
      surface: s.surfaceContainerLowest,
      ink: s.onSurface,
      border: s.outlineVariant,
      borderStrong: s.outline,
      muted: s.outline,
      muted2: s.onSurfaceVariant,
      accent: dark ? _accentTextDark : _accentTextLight,
      rust: s.error,
      syncOk: dark ? syncOkDark : syncOkLight,
      snack: s.inverseSurface,
      onSnack: s.onInverseSurface,
      onBrand: Colors.white,
      dialogBg: s.surfaceContainerLowest,
      selBg: dark ? const Color(0xFF2C1C14) : const Color(0xFFFFEDE4),
      isDark: dark,
    );
  }

  static final light = ClippyColors.of(_lightScheme);
  static final dark = ClippyColors.of(_darkScheme);

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

/// Text helpers over Instrument Sans. The ramp: 30/38 w700 · 24/32 w700 ·
/// 20/28 w600 · 18/24 w600 · 16/24 · 14/20 · 12/16 · 11/16. The helpers exist
/// so a screen names the ROLE it wants instead of restating a family at 60
/// call sites.
///
/// `color` is nullable on purpose. Passing null inherits from the enclosing
/// [DefaultTextStyle], which the theme paints with `onSurface`, so a helper
/// with no colour is correct in BOTH themes.
abstract class Ct {
  /// Headings, with the ramp's optical tracking (tighter as they grow).
  static TextStyle title(double size, {Color? color}) => TextStyle(
        fontFamily: appFontFamily,
        fontSize: size,
        fontWeight: size >= 24 ? FontWeight.w700 : FontWeight.w600,
        color: color,
        letterSpacing: size >= 24 ? -0.02 * size : 0,
        height: size >= 24 ? 1.27 : 1.4,
      );

  static TextStyle body(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.45,
  }) =>
      TextStyle(
        fontFamily: appFontFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
      );

  /// Keys, hashes and meta labels. ONE family is bundled, so this is
  /// Instrument Sans with tabular figures: digits line up in a column, which
  /// is what times, sizes and counts need. Slight tracking keeps a base64 key
  /// scannable.
  static TextStyle mono(
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w500,
  }) =>
      TextStyle(
        fontFamily: appFontFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1.5,
        letterSpacing: 0.4,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// The header wordmark: Instrument Sans semibold, tightly tracked.
  static TextStyle wordmark(double size, {Color? color}) => TextStyle(
        fontFamily: appFontFamily,
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: -0.035 * size,
        height: 1.1,
      );

  /// A clip's meta line ("MACBOOK · 2 MIN"): small caps-tracked label in the
  /// muted ink, with tabular figures so ages line up row to row.
  static TextStyle meta({Color? color}) => TextStyle(
        fontFamily: appFontFamily,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.9,
        height: 1.3,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// The small all-caps rule above a card group.
  static TextStyle sectionLabel({Color? color}) => TextStyle(
        fontFamily: appFontFamily,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
        color: color,
      );
}

/// Icon discipline: ONE language. Flutter's built-in ROUNDED Material set
/// (`Icons.*_rounded`), at three sizes, and nothing else.
///
/// Deliberately NOT `material_symbols_icons`, although Walletify ships it.
/// Walletify pays ~16 MB of APK for the Symbols variable fonts because its
/// category system renders server-named glyphs with weight/fill axes; that
/// price bought a real capability. Clippy draws ~25 static chrome glyphs and
/// has no dynamic icon names, so the same price would buy nothing here. The
/// built-in set is tree-shaken to the glyphs actually used (~a few KB), and
/// Walletify's own CHROME icons are `Icons.*_rounded` too, so the two apps'
/// chrome matches anyway. If Clippy ever grows server-driven icons, revisit.
abstract class ClipIcons {
  /// Header and navigation actions.
  static const double nav = 22;

  /// A row's leading glyph, drawn inside a [GlyphPlate].
  static const double row = 20;

  /// Inline glyphs: chips, buttons, meta rows.
  static const double inline = 16;
}

/// A tinted plate carrying one glyph (or a letter monogram). Clippy's version
/// of Walletify's `CategoryMark`, and the leading mark of every designed row
/// in the app: clip rows, settings rows, banners, sheet headers.
///
/// The plate/ink pair uses Walletify's blend formula, fed ONLY with scheme
/// roles: light gets a pale wash under deep ink, dark gets a deep wash under
/// pale ink. One formula everywhere is what makes the marks read as one
/// family; a mark that mixes its own colours is the drift this exists to stop.
///
/// The fallback is a LETTER, never a broken square (Walletify's rule): when no
/// glyph fits, an unrecognised device name, the monogram still gives the
/// thing a face.
class GlyphPlate extends StatelessWidget {
  final IconData? icon;
  final String? letter;

  /// The identity colour. A scheme role (`primary` / `tertiary` / `secondary`
  /// / `error`), usually via [deviceTint].
  final Color base;
  final double size;

  /// Circles mark IDENTITY (a device); squircles mark ACTIONS and kinds.
  final bool circle;

  const GlyphPlate({
    super.key,
    this.icon,
    this.letter,
    required this.base,
    this.size = 40,
    this.circle = false,
  }) : assert(icon != null || letter != null, 'glyph or letter required');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    // Walletify's audited pair: light = pale circle + deep glyph, dark = deep
    // circle + pale glyph. The light pair reused in dark would glare.
    final plate = dark
        ? Color.alphaBlend(base.withValues(alpha: 0.28), scheme.surface)
        : Color.alphaBlend(base.withValues(alpha: 0.16), Colors.white);
    final ink = dark
        ? Color.alphaBlend(base.withValues(alpha: 0.85), Colors.white)
        : Color.alphaBlend(base.withValues(alpha: 0.92), Colors.black);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: plate,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(size * 0.32),
      ),
      child: icon != null
          ? Icon(icon, size: size * 0.52, color: ink)
          : Text(
              letter!,
              style: Ct.body(size * 0.40, weight: FontWeight.w700, color: ink),
            ),
    );
  }
}

/// Content-independent, run-independent hash. `String.hashCode` is not
/// guaranteed stable across Dart versions, and a device that changes colour
/// after an app update would read as a different device.
int _stableHash(String s) {
  var h = 0;
  for (final unit in s.codeUnits) {
    h = (h * 31 + unit) & 0x7fffffff;
  }
  return h;
}

/// A device's stable identity colour: one of three measured hues,
/// picked by name. The header mark introduces the colour; the clip rows under
/// it repeat the colour on their kind plates, colour says WHERE a clip came
/// from, the glyph says WHAT it is.
Color deviceTint(ColorScheme scheme, String device) {
  final dark = scheme.brightness == Brightness.dark;
  // Never the signal orange: a device is identity, not a call to look.
  final bases = [
    scheme.tertiary,
    dark ? const Color(0xFF5ED3BF) : const Color(0xFF0F766E),
    dark ? const Color(0xFFB9A4FF) : const Color(0xFF6D4FD1),
  ];
  return bases[_stableHash(device.trim().toLowerCase()) % bases.length];
}

/// Best-effort platform glyph for a device name (Build.MODEL on Android,
/// hostname on desktop). Null means "no confident guess", the caller shows a
/// letter monogram instead, never a wrong platform.
IconData? deviceGlyph(String device) {
  final d = device.toLowerCase();
  if (d.contains('mac') || d.contains('imac')) return Icons.laptop_mac_rounded;
  if (d.contains('win') || d.contains('desktop') || d.contains('-pc')) {
    return Icons.desktop_windows_rounded;
  }
  if (d.contains('phone') ||
      d.contains('pixel') ||
      d.contains('galaxy') ||
      d.contains('android') ||
      d.startsWith('sm-') ||
      d.contains('oneplus') ||
      d.contains('xiaomi') ||
      d.contains('redmi')) {
    return Icons.smartphone_rounded;
  }
  return null;
}

/// The one sheet grabber: 36×4, drawn the same way on every sheet so a sheet
/// is recognisable as a sheet before its content is read. It was pasted in
/// three files before it became a widget.
class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 18),
        decoration: BoxDecoration(
          color: context.ck.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// The card vocabulary: `surfaceContainerLowest`, and **tone plus exactly ONE
/// edge per theme**, a soft neutral lift shadow in light, a hairline in dark,
/// where a shadow on a near-black canvas reads as a smudge. Never both, never
/// neither. Selected cards get an orange edge.
class ClipCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double radius;

  /// Overrides the fill; the selected clip row uses this for its brand tint.
  final Color? color;

  /// Draws the brand outline instead of the ordinary edge (selected state).
  final bool highlighted;

  const ClipCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.onLongPress,
    this.radius = 24,
    this.color,
    this.highlighted = false,
  });

  /// The one-edge rule as a reusable decoration, so banners and bars that are
  /// not cards still separate from the canvas the same way.
  static BoxDecoration decoration(
    BuildContext context, {
    double radius = 24,
    Color? color,
    bool highlighted = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final edge = highlighted
        ? signalOrangeBright.withValues(alpha: dark ? 0.70 : 0.60)
        : scheme.outlineVariant.withValues(alpha: dark ? 0.40 : 0.55);
    return BoxDecoration(
      color: color ?? scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(radius),
      border: dark || highlighted ? Border.all(color: edge) : null,
      boxShadow: dark
          ? null
          : [
              BoxShadow(
                color: highlighted
                    ? signalOrangeBright.withValues(alpha: 0.14)
                    : const Color(0xFF161614).withValues(alpha: 0.05),
                blurRadius: highlighted ? 18 : 12,
                offset: const Offset(0, 3),
              ),
            ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    return DecoratedBox(
      decoration:
          decoration(context, radius: radius, color: color, highlighted: highlighted),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        // Ink discipline: every tappable rounded surface is Material + InkWell
        // with Clip.antiAlias. A bare InkWell on a square Material flashes grey
        // corners on tap.
        clipBehavior: Clip.antiAlias,
        child: onTap == null && onLongPress == null
            ? body
            : InkWell(onTap: onTap, onLongPress: onLongPress, child: body),
      ),
    );
  }
}

ThemeData _build(ColorScheme scheme) {
  final base = (scheme.brightness == Brightness.dark
          ? Typography.material2021().white
          : Typography.material2021().black)
      .apply(fontFamily: appFontFamily);
  final text = base
      .copyWith(
        displayLarge: base.displayLarge?.copyWith(
            fontSize: 30,
            height: 38 / 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6),
        headlineMedium: base.headlineMedium
            ?.copyWith(fontSize: 24, height: 32 / 24, fontWeight: FontWeight.w700),
        titleLarge: base.titleLarge
            ?.copyWith(fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600),
        titleMedium: base.titleMedium
            ?.copyWith(fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w600),
        bodyLarge: base.bodyLarge
            ?.copyWith(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w400),
        bodyMedium: base.bodyMedium
            ?.copyWith(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400),
        bodySmall: base.bodySmall
            ?.copyWith(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w400),
        labelMedium: base.labelMedium?.copyWith(
            fontSize: 12,
            height: 16 / 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.12),
        labelSmall: base.labelSmall
            ?.copyWith(fontSize: 11, height: 16 / 11, fontWeight: FontWeight.w500),
      )
      .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text,
    splashFactory: InkSparkle.splashFactory,
    extensions: [ClippyColors.of(scheme)],
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        shape: const StadiumBorder(),
        textStyle: text.titleMedium?.copyWith(fontSize: 15),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.onSurface),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : null),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.onSurface,
      selectionColor: signalOrangeBright.withValues(alpha: 0.28),
      selectionHandleColor: signalOrangeBright,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
  );
}

final lightTheme = _build(_lightScheme);
final darkTheme = _build(_darkScheme);

/// The Clippy paperclip-with-eyes mark. Clippy keeps its mascot where
/// Walletify has none: Walletify's "nothing performs" law exists because every
/// figure it draws is a bank fact. Clippy draws clipboard entries, so a face
/// costs nothing and is the one thing that stops the two apps being the same
/// app in two colours.
class ClippyMark extends StatelessWidget {
  final double height;
  final String clipHex;
  final String eyeHex;
  final String eyeFill;

  const ClippyMark({
    super.key,
    this.height = 24,
    this.clipHex = '161614',
    this.eyeHex = '161614',
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

/// The mark, alive: it bobs gently and blinks. Used in the header and on the
/// pairing screen; the static [ClippyMark] stays for empty states.
class AnimatedClippyMark extends StatefulWidget {
  final double height;
  final String clipHex;
  final String eyeHex;
  final String eyeFill;

  const AnimatedClippyMark({
    super.key,
    this.height = 24,
    this.clipHex = '161614',
    this.eyeHex = '161614',
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
