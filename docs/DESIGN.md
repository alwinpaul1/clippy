# DESIGN.md. Clippy

> **Source of truth is `lib/app/theme.dart`.** Where this file and the Dart
> disagree, the Dart wins. This document exists for the REASONS; the values are
> in the code and only summarised here.

Rewritten 2026-10-18 for the "paper and graphite" redesign. It replaces the
violet Material 3 system Clippy used to share with Walletify. The owner asked
for a new palette (researched on Mobbin), Instrument Sans, the paperclip
mascot kept, and the pairing screen redesigned. That last point reverses the
earlier "keep the old pairing layout" decision on purpose.

## Brand & style

**Paper and graphite, with one signal orange.** The canvas is warm off-white
paper (`#F5F4F0`) in light and near-black graphite (`#0F0F0E`) in dark. Ink is
near-black or near-white, never pure. One saturated colour exists: signal
orange (`#C2410C` as a fill, brighter tints as marks and text). Everything
else is greys, so whatever is orange is what you look at.

Clippy is no longer Walletify's sibling in colour. It keeps two things from
that era: the hand-built dark scheme (a seeded dark scheme muddies every
accent), and a lighter hand than Walletify on motion, because nothing here can
mislead by moving. The paperclip may bob and blink.

**Orange is a signal, not an identity.** It marks the update hero, the
selection checkbox, a highlighted card's edge, text selection, the "Fix" and
"View" links in banners and the key warning. It does NOT mark:

- **links in clips.** These are ink with an underline. An orange-red link next
  to a red error reads as a fault.
- **devices.** `deviceTint` draws from tertiary blue, teal and violet. A device
  is identity, not a call to look.
- **"Clear all".** It is muted. Its confirm dialog carries the warning.
- **the primary button.** Filled buttons are an ink pill: dark on paper in
  light, light on graphite in dark. A wall of orange buttons would spend the
  signal on every screen.

## Colours

`_lightScheme` / `_darkScheme` in `theme.dart`, both hand-built:

| role | light | dark | job |
|---|---|---|---|
| `primary` | `#161614` ink | `#F3F2EE` | filled buttons, selected pill segment |
| `secondary` | `#C2410C` | `#FF7A45` | the signal |
| `tertiary` | `#1D5FD0` | `#7DA8FF` | device tint, improvements mark |
| `surface` | `#F5F4F0` | `#0F0F0E` | the page |
| `surfaceContainerLowest` | white | `#1A1A18` | cards, sheets, dialogs |
| `outline` | `#615F59` | `#9A9893` | `muted` text AND control edges |
| `outlineVariant` | `#E2E0DA` | `#2E2D2A` | hairlines only |

Named constants carry jobs that no single role can do:

| token | why it exists |
|---|---|
| `signalOrange` / `signalOrangeDeep` | the gradient's two ends; white clears ≥ 5.18:1 on both |
| `signalOrangeBright` `#FF5A1F` | orange as a non-text mark (dots, edges) |
| `_accentTextLight/Dark` | orange as TEXT: `#B93A0A` / `#FF7A45`, both ≥ 4.5:1 on cards |
| `syncOkLight/Dark` | the sync light, see below |
| `scannerBg` | the QR scanner and the image viewer, dark in both themes |

### The sync light

The status pill under the wordmark is **green** (`#0B7A45` light, `#4CCE8A`
dark) when the UI's connection AND background sync are alive, red otherwise.
It is not orange. A status light in the signal colour reads as a warning, and
green and red are the one colour code that needs no legend. It reports both
connections because a dot that meant only "the UI's socket is up" once stayed
green through a six-hour background outage.

**The gradient** (`signalOrange → signalOrangeDeep`) marks one moment: the
update sheet's version hero. It is never a surface. Text on it is
`ClippyColors.onBrand`, which is white in BOTH themes because the gradient is
the same in both. Do not point `onBrand` at `onPrimary`: that flips to dark
ink in dark mode. It did, and the dark hero printed dark ink on orange.

**Tone plus exactly ONE edge per theme.** A card separates from the canvas by
a soft neutral shadow in light, **or** a hairline in dark, where a shadow on
near-black reads as a smudge. Never both, never neither. `ClipCard` implements
it once.

## The palette adapter

`ClippyColors` (`context.ck`) is derived from the scheme (`ClippyColors.of`).
It holds the roles M3 has no single name for: `muted` / `muted2`, `accent`
(orange as text), `syncOk`, the snackbar pair, `onBrand` and `selBg`.
Everything that maps to a scheme role **is** that role.

## Typography

**Instrument Sans, bundled** (`assets/fonts/InstrumentSans-*.ttf`, weights
400/500/600/700, `OFL-InstrumentSans.txt` alongside as the SIL licence
requires). It is the app face AND the wordmark. The old second font, a
six-letter Newsreader subset, is gone. So is Plus Jakarta Sans.

- `Ct.wordmark`: "Clippy" in w600, tracked tight (-0.035 em).
- `Ct.title` / `Ct.body`: the ramp.
- `Ct.meta`: 11 px w600, tracked +0.9, tabular figures, uppercase at the call
  site. Every meta line uses it ("MACBOOK PRO · 2 MIN · LINK") and so do the
  section labels.
- `Ct.mono`: **not a monospace font.** Clippy bundles one family, so this is
  Instrument Sans with tabular figures and a little tracking. Digits line up;
  letters do not. Code clips therefore render in the body face, and their
  CODE meta tag says what they are.

The helpers' `color` is nullable: null inherits `onSurface` from the theme,
which is correct in both modes.

## Icons

Flutter's built-in rounded set (`Icons.*_rounded`) at three sizes:
`ClipIcons.nav` 22, `ClipIcons.row` 20, `ClipIcons.inline` 16. The
`material_symbols_icons` package was rejected because its variable fonts cost
about 16 MB, and Clippy draws about 25 static glyphs.

## Marks

`GlyphPlate` is one glyph on a tinted plate, with plate and ink derived from
ONE base colour (light: pale wash + deep ink; dark: deep wash + pale ink).
**Circles mark identity** (a device). **Squircles mark actions and kinds.**
An unrecognised device name gets a letter monogram, never a wrong platform
glyph. `deviceTint` hashes the name with its own stable hash, because a device
must not change colour after a Dart upgrade.

## The screens

- **Home** is one reading column (720 px max). The header, toolbar, feed and
  bottom banner all share it, so on a wide desktop window they line up instead
  of the chrome stretching while the clips stay centred (`_Column` in
  `home_page.dart`).
  - The header holds the mascot, the "Clippy" wordmark, round Devices and
    Settings buttons, and the sync pill. Unpair moved out to Settings: a
    destructive action does not belong one tap from the main screen.
  - The toolbar holds search, an All / Text / Links / Images filter
    (`PillSegments`) and a quiet "Clear all".
  - The feed is grouped Today / Yesterday / This week / Earlier. Each card has
    a meta line (device glyph, DEVICE · AGE · KIND), the content, and a round
    copy button. Images run full width up to 180 px tall. Swipe deletes;
    long-press enters selection, and an ink pill bar replaces the header.
- **Devices** (new). This device with its live connection, then every other
  device that has put a clip in the shared history, with "Last clip N ago · N
  clips". The relay has no presence, so last activity is the honest signal; a
  device is never shown "online" on a guess. One primary action: Add a device.
- **Add a device** is a sheet shared by Devices, Settings and the empty state.
  It has a QR / Key toggle, the key's password warning and "Copy key".
- **Settings**: the Appearance segments, the Android background-sync
  checklist (progress track, numbered steps that turn into green ticks),
  Devices, About, and a separate, red "Unpair this device" row.
- **Pairing**: the mascot, "Pair your devices", one card holding the GROUP KEY
  field, "New key" and "Scan QR code", and the QR once a key exists. Below it
  sit the ink "Pair this device" button and the end-to-end note.
- **The update card** (`update_card.dart`) floats above EVERY screen,
  mounted from `MaterialApp.builder`, after the Code UI / Orca desktop card.
  On a window 480 px or wider it is 360 px in the bottom-right corner; on a
  phone it spans the width with 16 px gutters, and home lifts its own bottom
  banner and feed padding by `UpdateCardHost.occupied`. It slides in from the
  right in 200 ms, or appears in place under reduced motion. Its states:
  - Available: "Update available", "Clippy X is ready…", a "See what's new"
    link to the changelog sheet, a full-width Update button, and an X that
    remembers the dismissed version.
  - Downloading: a progress bar, with no X.
  - Failed: "Try again".

  It replaced a home-only bottom banner that lost to two Android warnings, so
  a release could go unseen. It sits above the Navigator, so it has no Overlay:
  never give it a Tooltip.
- **Previews**: a text clip opens a bottom sheet (selectable text, Copy,
  Delete); an image opens a full-screen dark viewer.

## Motion

What moves: the mascot (bob + blink), the header ↔ selection-bar swap
(200 ms), the copy button's tick, the pill segments (160 ms), the sync-step
badges and track, and the pairing card's QR reveal. Everything else is still.

## Navigation

No tab bar or nav pill. Clippy has one surface (the clip list) and three
rarely visited destinations (Devices, Settings, pairing). A permanent bar
would spend 60 dp on the most list-dense screen to make rare trips one tap
cheaper, and a floating phone pill under a desktop mouse pointer is a phone
gesture in a desktop costume. Revisit only if Clippy grows a second real
surface.

## Surfaces

- **`ClipCard`**: radius 24 (20 for rows, groups and banners) on
  `surfaceContainerLowest`, following the one-edge rule.
- **Round controls**: `RoundIconButton` is a 40 px filled circle, hairlined
  in dark. On the bare paper canvas a naked glyph floats; a filled circle reads
  as a control.
- **Ink discipline**: every tappable rounded surface is `Material` + `InkWell`
  with `Clip.antiAlias`, or the tap flashes grey corners.
- **Sheets** share `SheetGrabber` and a 28 radius. They must scroll, not
  overflow: pin the buttons and let the explainer scroll.
- **One warning shape**: `_WarnBanner` on home. The error tint carries the
  alarm; the surface stays an ordinary card.

## Deliberate exceptions

1. **The QR scanner and the image viewer are dark in both themes** and do not
   read `context.ck`. A camera preview and a photo both need a neutral dark
   frame.
2. **The QR quiet zone is true white in both themes.** A scanner requirement,
   not a colour choice.
3. **The selection checkbox fills with `signalOrange` in both themes.** It
   carries a white tick at 5.18:1.

## Contrast

`scripts/check_contrast.py` is the gate. Run it with
`uv run python scripts/check_contrast.py` after touching any colour. It parses
`theme.dart`, `qr_scanner_page.dart` and `clip_preview.dart` themselves, never
a hand-copied list. It composites alpha over the real backdrop and exits
non-zero on any failure.

Its first run on this palette found a real defect: `muted` (`outline`) text
fell to 3.73–4.46:1 on the container tiers. The theme had "handled" it with a
comment telling call sites to avoid one tier. `outline` moved instead (light
`#6F6D67 → #615F59`, dark `#8F8D86 → #9A9893`) and now clears 4.5:1 on all six
tiers. The image viewer's meta colour, a documented copy of dark `outline`,
moved with it; the gate's drift check is what catches the two diverging.

**The two border tokens are not interchangeable.** `border`
(`outlineVariant`) is for hairlines and dividers and is exempt, because low
contrast is the point. `borderStrong` (`outline`) is the edge of an actual
control and owes 3:1. If a control's only edge is drawn with `c.border`, fix
the call site; do not darken the hairline.

**What the gate does NOT see**: pressed / hover / focus / disabled state
layers, WCAG's relaxed 3:1 for large text (so big headings are over-reported),
`selBg`, and any file that hardcodes its own colour without being added to
the script.
