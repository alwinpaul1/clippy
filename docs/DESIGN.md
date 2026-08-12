# DESIGN.md. Clippy

> **Source of truth is `lib/app/theme.dart`.** Where this file and the Dart
> disagree, the Dart wins. This document exists for the REASONS; the values are
> in the code and only summarised here.

Rewritten 2026-08-12, when Clippy moved from its warm-editorial palette to the
violet Material 3 system it now shares with **Walletify**.

## Brand & style

Clippy and Walletify are the same owner's apps and are meant to read as
siblings: one Material 3 scheme seeded from the violet `#7C3AED` / `#630ED4`
family, one face (**Plus Jakarta Sans**), one card vocabulary, both themes
shipped as equals.

What Clippy keeps of its own is **the mascot and a lighter hand**. Walletify's
"nothing performs, no figure is ever animated" law exists because every number
Walletify draws is a booked bank fact and trust is its product. Clippy draws
clipboard entries. Nothing here can mislead by moving, so the paperclip is
allowed to bob and blink, and the app is allowed to be a little friendly.
**Do not import Walletify's motion law into this app; it is answering a
question Clippy does not have.**

What went, and is not coming back: the cream `#F4F1EA` canvas, the ink
`#1E1C15`, the deep green `#1F4B3F`, IBM Plex Mono, and the runtime
`google_fonts` fetch.

**Two things were kept back from the old design at the owner's request, after
seeing the first violet build:**

- **The header mark and wordmark.** The mascot is plain **ink**, not violet,
  and the wordmark keeps its **Newsreader serif**. One bar is the app's own
  signature; the violet system runs everywhere else. The mascot is ink on the
  pairing screen too, it is one face with one colour, everywhere.
- **The sync light stays green.** See *The sync light* below.
- **The pairing screen keeps its OLD layout.** The owner reviewed the
  redesigned pairing screen and asked for the previous structure back with
  only the colours updated ("revert this to old but keep the same colors like
  new"). So it is the loose ink mascot with no plate behind it, the old sizes
  and spacing, the old bordered key field, and PLAIN outlined/filled action
  buttons, painted with the violet system's tokens. Old bones, new paint.
  Do not re-redesign it; the layout there is a decision, not a leftover.

## Colours

The two `ColorScheme`s in `lib/app/theme.dart` are **copied verbatim from
Walletify's `app/lib/core/theme.dart`**, where they were contrast-audited on
2026-08-12. Copying the audited values keeps that work rather than re-deriving
it, and it is what keeps the two apps from drifting apart.

**Dark is hand-built, not seeded.** A `ColorScheme.fromSeed` dark scheme
desaturates every accent into mud. If you re-derive dark from a seed, the
accents die first. This is recorded in Walletify's own DESIGN.md as a reported
regression; do not rediscover it here.

Three tokens exist because one value cannot do two jobs:

| token | why it exists |
|---|---|
| `primaryFillDark` `#8554F6` | the dark theme's filled-button **background**. Dark `primary` `#8B5CF6` is also used as INK on dark surfaces, where it must stay light. A solid fill under white text needs the opposite. White cannot move, so the fill got its own token. |
| `primaryTextDark` `#A98BFF` | brand violet as **body text** on a dark surface. Dark `primary` measures 4.35:1, fine for an icon or border (3:1), short of the 4.5:1 text needs. |
| `scannerBg` `#15131A` | the QR scanner and the image viewer. Both are dark in BOTH themes on purpose, see *Deliberate exceptions*. |

### The sync light

The "Synced / Reconnecting / Background sync stopped" dot is **green**
(`#0B7A45` light, `#4CCE8A` dark. Walletify's audited positive pair) and red
on trouble. It is deliberately **not** the brand violet.

A state light painted in the brand colour stops reading as a signal and starts
reading as decoration, and the header already carries violet elsewhere. Green
and red are also the one colour code that needs no legend. The token is
`ClippyColors.syncOk`; do not "unify" it with `accent`.

**The gradient** (`#7C3AED → #630ED4`, top-left to bottom-right) marks moments,
never surfaces. It appears in exactly **two** places: the selection bar (a
*mode*, not a decoration, the whole bar changing is what tells you the list
now behaves differently) and the update sheet's version hero. It must not
become a general background. The "Pair this device" button *was* the third
place; it went back to a plain filled button when the owner reverted the
pairing screen's layout, and the count in this rule changed with it.

**Tone plus exactly ONE edge per theme.** A card separates from the canvas by a
violet-tinted lift shadow in light, **or** a hairline in dark, where a shadow on
a near-black canvas reads as a smudge. Never both, never neither. This is
implemented once, in `ClipCard.decoration`, and every card, banner and bar goes
through it.

## The palette adapter

`ClippyColors` survived the rewrite, but it is now **derived from the scheme**
(`ClippyColors.of`) instead of hand-listed. It stays for two reasons: about
fifty call sites read it through `context.ck`, and a few of Clippy's roles have
no single M3 role to point at, the snackbar pair, the selected-row tint, and
the ink that sits on the brand gradient. Everything that *does* map to a role
**is** that role.

Two renames carry meaning:

- `green` → **`accent`**. It holds violet now. A field called `green` full of
  violet is exactly the trap the next reader falls into.
- The old `Ck` static-light class is **gone**. It was a light-mode constant set
  used as "the pale ink that reads on a dark chip", which stopped being true
  the moment the snackbar started flipping with the theme. `onSnack` and
  `onBrand` name those two jobs properly.

## Typography

**Plus Jakarta Sans, bundled as assets** (`assets/fonts/`, declared in
`pubspec.yaml`, `OFL.txt` travels with the files as the SIL licence requires).
The `google_fonts` dependency is removed. It used to pull three families from
Google's CDN on first launch, which delayed first paint and needed a working
connection to render an app that is otherwise happy offline.

One ramp for the whole app, the same one Walletify runs: **30/38 w700 ·
24/32 w700 · 20/28 w600 · 18/24 w600 · 16/24 · 14/20 · 12/16 · 11/16 w500**.

`Ct.title` / `Ct.body` / `Ct.mono` / `Ct.sectionLabel` exist so a screen names
the ROLE it wants rather than restating a font family at sixty call sites.
**Their `color` is nullable on purpose:** passing null inherits from the
enclosing `DefaultTextStyle`, which the theme paints with `onSurface`, so a
helper with no colour is correct in both themes. The old helpers defaulted to a
static light-mode constant, which was invisible on a dark canvas.

**The wordmark is a second, one-word font.** `Ct.wordmark` draws the header's
"Clippy" in Newsreader, instanced to wght=500/opsz=36 and then **subset to the
six letters of that word**, 451 KB of variable font reduced to **2 KB**, which
is why keeping the serif costs the bundle almost nothing.

> **It can draw exactly one word. Every other character is tofu.** Use it only
> through `Ct.wordmark`. If the app is ever renamed, regenerate the subset with
> the new letters:
> ```
> fonttools varLib.instancer Newsreader.ttf wght=500 opsz=36 -o tmp.ttf
> pyftsubset tmp.ttf --text="Clippy" --output-file=Newsreader-Wordmark.ttf \
>   --no-hinting --desubroutinize
> ```

**`Ct.mono` is not a monospace font.** Clippy bundles ONE family, so it is
Jakarta with `FontFeature.tabularFigures()` and a little extra tracking.
`hb-shape --features=tnum` measures every Jakarta digit at exactly 0.600 em, so
figures line up in a column; the letters do not. A real mono would align the
letters too. That is not worth a second font file for one pairing key, but it
IS the trade-off, stated so nobody assumes the key field is monospaced.

## Icons, one language, and why it is NOT the Symbols package

**Every glyph is Flutter's built-in rounded set (`Icons.*_rounded`), at three
sizes only**, `ClipIcons.nav` 22 (header/nav), `ClipIcons.row` 20 (a row's
leading glyph, inside a plate), `ClipIcons.inline` 16 (chips, buttons, meta).
The old screens mixed `_outlined`, filled and bare-named glyphs at eight ad
hoc sizes; that mix is what made them read as stock.

Walletify ships `material_symbols_icons`, and matching it was considered and
**rejected on cost**: Walletify's own DESIGN.md records that the Symbols
VARIABLE fonts grew its APK by roughly **16 MB**, a price that bought a real
capability, 3,800 server-named category glyphs with weight/fill axes. Clippy
draws about 25 static chrome glyphs and has no dynamic icon names, so the same
16 MB would buy nothing here. The built-in rounded set is tree-shaken to the
glyphs actually used (a few KB), and Walletify's own CHROME icons are
`Icons.*_rounded` anyway, so the two apps' chrome matches without the
package. If Clippy ever needs server-driven icons, that is the fact that
reopens this decision.

## Marks, the tinted-plate vocabulary

`GlyphPlate` is Clippy's version of Walletify's `CategoryMark`: one glyph on a
tinted plate, plate/ink derived from ONE base colour with Walletify's blend
formula (light: pale wash + deep ink; dark: deep wash + pale ink, the light
pair reused in dark would glare). Bases are **scheme roles only**; a mark that
mixes its own colours is exactly the drift the formula exists to stop.
**Circles mark identity** (a device); **squircles mark actions and kinds**
(settings rows, clip kinds, banner icons). The fallback is a **letter, never a
broken square**, an unrecognised device name gets a monogram, not a wrong
platform glyph.

**Device identity: colour says WHERE, glyph says WHAT.** `deviceTint` hashes
the device name (own stable hash, `String.hashCode` is not guaranteed stable
across Dart versions, and a device must not change colour after an update)
into one of three scheme roles: `primary`, `tertiary`, `secondary`. The device
group header introduces the colour on its circle mark; every clip row under it
repeats the colour on its kind plate, whose glyph is the clip's KIND (text /
link / code; images show their own thumbnail). Four kinds only, the
distinctions a user acts on. Finer taxonomy would be decoration.

## The screens, what changed beyond colour, and why

- **Home hierarchy.** The single newest clip renders larger, with a LATEST
  chip and a three-line preview, it is the clip the user opened the app to
  paste, and the hierarchy should say so. It stays the first row of the first
  group (groups are newest-first), so it is a treatment, not a second copy of
  the data: selection, swipe-delete and preview all keep working on it.
- **Device group headers** went from a bare ALL-CAPS string to identity
  objects: circle mark, name, count pill, and the fold chevron moved to the
  trailing edge where disclosure belongs.
- **Meta lines** read kind · size · age, in that order, the order the eye
  asks the questions in. Text length appears only past 100 chars, when the
  preview visibly truncates; "12 chars" is noise.
- **The empty state** got a title, one honest sentence and a real "Add another
  device" action. The old copy said "add one below" and nothing existed below
, the promised control exists now, and an empty list usually does mean the
  group has one device.
- **Settings**: the theme choice is a segmented control (one pick from three
  visible peers, three radio rows spent a card saying the same thing), and
  every action row leads with a plate.
- **Background sync reads as the sequence it is**: a summary header, a
  progress track with one segment per step, then numbered steps whose badges
  fill into ticks as permissions land. The card is built from a `_SyncStep`
  LIST, the third step Android will soon require (battery) is one appended
  entry plus its status field, not a redesign.
- **The permission sheet's steps sit on a connected rail**, the line between
  the badges is what makes three sentences read as one procedure with an
  order, not three tips.
- **The update sheet's sections** carry marks on three scheme roles (features
  = spark on primary, improvements on tertiary, fixes on secondary); the
  update banner shares the home banners' anatomy (plate, message, action),
  tinted brand instead of error because news is not a fault.
- **The QR scanner** gained a torch toggle (hidden when the device reports no
  torch) and a chip-framed hint. Still dark in both themes; that exception
  stands.

## Motion, the budget, spent in full

Clippy is allowed more delight than Walletify (see *Brand & style*), but
motion is still a budget, not a garnish. What moves: the mascot (bob + blink),
the header ↔ selection-bar swap (200 ms fade + drop, the mode change is the
message), the copy button's tick (the copy is invisible; the button is the
only place that can confirm it), the sync-step badges and track (progress),
the theme segments, and the fold chevrons. Everything else is still. Figures
never animate, not because of Walletify's law, but because nothing here earns
it.

## Navigation, the decision, and why there is no nav pill

**Clippy does not get Walletify's floating nav pill.** Its chrome stays the
frosted-glass header with the mascot, the wordmark, the honest status line and
three icon buttons; Devices and Settings stay pushed pages.

Walletify's pill is right *there* because Walletify has four genuinely co-equal
surfaces that a user moves between constantly. Clippy has **one** surface,
the clip list, plus two destinations that are visited rarely (pairing a few
times ever, settings occasionally). A three-slot bar would spend about 60 dp of
permanent vertical space, on the most list-dense screen in the app, to make two
rare destinations one tap cheaper. That is chrome bought with the content's
space.

It also would not have survived the platform rule: the same look ships on
Android, macOS and Windows, and a floating phone pill under a mouse pointer is
a phone gesture wearing a desktop costume.

So: **the same design system, a different amount of chrome.** If Clippy ever
grows a second real surface, revisit this, that is the condition that changes
the answer, not a wish for the two apps to look more alike.

## Surfaces

- **The card** is `ClipCard`: radius 24 (20 for the denser rows and banners),
  `surfaceContainerLowest`, the one-edge rule above. One vocabulary per screen,
  so a page reads as one system.
- **Ink discipline.** Every tappable rounded surface is `Material` + `InkWell`
  with `Clip.antiAlias`, which `ClipCard` does for you. A bare `InkWell` on a
  square `Material` flashes grey corners on tap.
- **Sheets** open with the same 36×4 grabber and a 28 radius, so a sheet is
  recognisable as a sheet before its content is read. The grabber is one
  widget (`SheetGrabber`), it was pasted into three files before that.
- **Sheets must give.** A sheet built as a fixed `mainAxisSize.min` Column
  overflows instead of scrolling the moment its content or the screen changes.
  The permission sheet shipped exactly that bug in this rewrite and a test
  caught it at 2 px. Pin the buttons, let the explainer scroll.
- **One warning shape.** Both pinned warnings on the home screen were the same
  forty lines with two words changed. They are one `_WarnBanner` now. The error
  tint carries the alarm and the surface stays an ordinary card, a fully red
  banner reads as a crash, and neither state is one; the clip list keeps
  working while they show.

## Deliberate exceptions

Recorded so nobody "fixes" them:

1. **The QR scanner and the image viewer are dark in both themes** and do not
   read `context.ck`. A camera preview needs a neutral dark frame, and a
   full-screen viewer that repaints its chrome white washes out the picture it
   exists to show.
2. **The QR quiet zone is true white in both themes.** A QR code needs a real
   white margin to scan reliably. This is a scanner requirement, not a colour
   choice.
3. **The selection checkbox uses `primaryFillDark`, not `accent`.** It is a
   filled brand chip, and `accent` is the *lighter ink* violet in dark mode,
   a white tick on it would sit near 2:1.

## Contrast

**Clippy now has its own gate: `scripts/check_contrast.py`.** It parses
`lib/app/theme.dart`, never a hand-copied duplicate, which goes stale silently
, plus the two screens with fixed dark chrome, composites alpha over its real
backdrop before scoring, and prints the threshold and the reason for every pair.
It exits non-zero on failure. Run it after touching any colour.

The first run found real defects and they are fixed:

**The two border tokens are not interchangeable, and only one owes 3:1.**
WCAG 1.4.11 covers graphics needed to identify a *control*; it exempts pure
decoration. Material 3 splits them deliberately, and so do we:

| token | job | owes |
|---|---|---|
| `border` (`outlineVariant`) | dividers, card hairlines, sheet grabbers, the frame round a QR quiet zone | nothing, low contrast is the POINT, see *tone plus one edge* |
| `borderStrong` (`outline`) | the edge of an actual control, outlined button, chip, text field | **3:1** |

`outlineVariant` measures ~1.3, 1.7:1 on every surface tier in both themes. That
is correct for a hairline and **wrong for a control's only edge**, and four
places had it doing the second job: the two header chips, the permission
sheet's outlined button, and the pairing key field. They now use
`borderStrong`. **Do not "fix" this by darkening `outlineVariant`**, that
buys a green number by destroying the card system's hairline. Fix the call
site instead.

The image viewer's delete-button ring also failed at 2.36:1 and went from 35 %
to 45 % alpha. The `danger` token itself did not move, because the delete
*glyph* shares it and already measures 10.85:1.

**Two dark pairs are logged as LATENT, not failed:** `onPrimary`/`primary`
(4.23:1) and `onTertiaryContainer`/`tertiaryContainer` (4.43:1). Neither has a
call site, white already routes through `primaryFillDark` (4.57:1), and the
tertiary container role is unused. They are not nudged to green because both
schemes are copied verbatim from Walletify's audit and a cosmetic tweak here
would buy a passing number with real drift. `LATENT_PAIRS` in the script
records the exact condition that makes each one fatal. **If you are about to
render one, delete its entry, watch the gate go red, and fix it first.**

**What the gate does NOT see**, stated because a gate trusted beyond its reach
is worse than none: pressed / hover / focus / disabled state layers; the real
backdrop behind `_GlassHeader`'s blur, where live content scrolls under the
sync dot; WCAG's relaxed 3:1 for large or bold text, so big headings are
over-reported; `selBg`; and any future file that hardcodes its own colour, which
is invisible until someone adds it to the script by name.
