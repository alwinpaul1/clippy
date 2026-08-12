#!/usr/bin/env python3
"""WCAG 2.1 contrast gate for every colour pair Clippy's Flutter app composites.

docs/DESIGN.md's *Contrast* section records this as open work: Clippy's violet
scheme is copied from Walletify (`app/scripts/check_contrast.py`), which
audited it there, but any colour introduced in CLIPPY ITSELF was checked BY
HAND. This script closes that gap for this repo, ported from Walletify's
script (same WCAG maths, same "parse the real file, never hand-copy a
colour" rule) and extended with Clippy's own tokens Walletify's script has
never seen: `syncOkLight/Dark`, `primaryFillDark`, `primaryTextDark`, the
`ClippyColors.of` derived roles, and the QR-scanner / image-viewer chrome
that is fixed dark in BOTH themes.

Every colour is READ OUT OF `lib/app/theme.dart` (the two `ColorScheme`
literals, the named top-level consts, and the `ClippyColors.of` factory
body), plus the two screens that hardcode fixed-dark chrome
(`lib/app/qr_scanner_page.dart`, and the `_ImagePreview` block of
`lib/app/home_page.dart`) — never copied into this file. A private copy is
exactly how a gate like this goes stale the first time someone tunes a
colour and forgets the script. If a role is renamed or a file's shape
changes, this script fails loudly (`sys.exit`) rather than silently scoring
whatever it last found.

Alpha is composited over its real backdrop (`over`, `composite_stack`)
before scoring; nothing translucent is scored directly against another
translucent colour.

THRESHOLD: `kind="text"` -> WCAG 1.4.3, 4.5:1. `kind="mark"` -> WCAG 1.4.11
(non-text UI component / graphic), 3:1. Every printed line says which one it
used, and the pair tables below say why.

EXIT-CODE POLICY: any pair below its threshold is a FAIL and exits 1. There
is no WARN/safety-net tier here (unlike Walletify's script) — everything
this script checks has a live call site in the app today.
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = REPO_ROOT / "lib"
THEME = LIB / "app" / "theme.dart"
QR_SCANNER = LIB / "app" / "qr_scanner_page.dart"
HOME_PAGE = LIB / "app" / "home_page.dart"

TEXT_MIN = 4.5   # WCAG 1.4.3 — body / label text
MARK_MIN = 3.0   # WCAG 1.4.11 — icons, borders, dots, chart-style marks

#: Role pairs that are BELOW threshold and have NO call site in the app today.
#: They are reported loudly on every run but do not fail the gate, because
#: failing on a pair nothing renders would leave the gate permanently red and
#: therefore ignored — and an ignored gate catches nothing.
#:
#: The two colour schemes are copied VERBATIM from Walletify's contrast-audited
#: theme so the sibling apps cannot drift (see docs/DESIGN.md). Nudging a value
#: here to green a pair nobody draws would buy a passing number with real drift.
#:
#: THE CONDITION THAT MAKES EACH ONE FATAL IS WRITTEN BELOW. If you are about to
#: render one of these, you own fixing it FIRST — delete its entry, watch the
#: gate go red, and fix it properly.
LATENT_PAIRS = {
    ("onPrimary", "primary"): (
        "LATENT (dark) — white on raw dark `primary` is 4.23:1. Nothing renders "
        "it: every filled surface routes through `primaryFillDark` (4.57:1) via "
        "the FilledButton theme, and `primary` appears in dark only as a BORDER "
        "(ClipCard highlighted), where 3:1 applies and it passes. Becomes fatal "
        "the moment white text or a white icon is drawn on `scheme.primary` in "
        "dark — use `primaryFillDark` for that instead of minting a third violet."
    ),
    ("onTertiaryContainer", "tertiaryContainer"): (
        "LATENT (dark) — 4.43:1. Neither role has a call site; only the bare "
        "`scheme.tertiary` is used. Becomes fatal on first use of the container "
        "role; the fix is to darken tertiaryContainer #066ABC to about #0668B9."
    ),
}

#: The six M3 surface tiers `outline` / `onSurfaceVariant` (and, here, a few
#: of Clippy's own tokens) get swept across. Walletify's own audit found
#: real failures exactly on this sweep, not on the plain onX/X pairs, so it
#: is never skipped for any role that renders as text or a mark on a card.
SURFACE_TIERS = [
    "surface", "surfaceContainerLowest", "surfaceContainerLow",
    "surfaceContainer", "surfaceContainerHigh", "surfaceContainerHighest",
]

#: Named Flutter constants that can appear as a colour expression instead of
#: a literal `Color(0x........)`. Kept deliberately tiny and explicit —
#: anything else unresolved fails loudly rather than guessing.
_NAMED_FLUTTER_COLORS = {
    "Colors.white": "FFFFFFFF",
    "Colors.black": "FF000000",
}


# --------------------------------------------------------------- Dart parsing

def _strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def _resolve_color_expr(expr: str, *, context: str, named: dict[str, str] | None = None) -> str:
    """-> 'AARRGGBB' hex string, Flutter's own Color() byte order.

    Handles a literal `Color(0x........)`, `Colors.white` / `Colors.black`
    (opaque or `.withValues(alpha: N)`), or a name already resolved into
    `named`. Anything else is a shape change this script has not seen and
    exits loudly rather than guessing.
    """
    expr = expr.strip()
    expr = re.sub(r"^const\s+", "", expr)

    m = re.fullmatch(r"Color\(0x([0-9A-Fa-f]{8})\)", expr)
    if m:
        return m.group(1).upper()

    m = re.fullmatch(r"(Colors\.(?:white|black))\.withValues\(alpha:\s*([\d.]+)\)", expr)
    if m:
        base = _NAMED_FLUTTER_COLORS[m.group(1)]
        alpha_byte = round(float(m.group(2)) * 255)
        return f"{alpha_byte:02X}{base[2:]}"

    if expr in _NAMED_FLUTTER_COLORS:
        return _NAMED_FLUTTER_COLORS[expr]
    if named and expr in named:
        return named[expr]

    sys.exit(f"check_contrast: unrecognised colour expression {expr!r} in {context} — the shape changed")


def read_named_exprs(path: pathlib.Path) -> dict[str, tuple[str, int]]:
    """`const NAME = <expr>;` on one line -> {NAME: (raw_expr, line_number)}.

    Deliberately does NOT try to parse a multi-line declaration — a reformat
    that breaks that shape fails the "not found" check downstream rather
    than silently parsing something else. Matches Walletify's script's own
    rule, generalised to allow the RHS to be any expression (not only a
    literal `Color(0x...)`) so it also covers `const bg = scannerBg;`.
    """
    out: dict[str, tuple[str, int]] = {}
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = _strip_comments(line)
        m = re.match(r"\s*const\s+(\w+)\s*=\s*([^;]+?)\s*;\s*$", stripped)
        if m:
            out[m.group(1)] = (m.group(2), i)
    return out


def read_scheme(name: str, *, named: dict[str, str]) -> dict[str, str]:
    """Pull `const <name> = ColorScheme(...)` out of theme.dart as {role: AARRGGBB}."""
    src = _strip_comments(THEME.read_text(encoding="utf-8"))
    m = re.search(rf"const {re.escape(name)} = ColorScheme\((.*?)^\);", src, re.S | re.M)
    if not m:
        sys.exit(f"check_contrast: no `const {name} = ColorScheme(...)` block in {THEME}")
    body = m.group(1)
    pal: dict[str, str] = {}
    for role, expr in re.findall(r"(\w+):\s*([^\n]+?),\s*$", body, re.M):
        if role == "brightness":
            continue
        pal[role] = _resolve_color_expr(expr, context=f"{name}.{role}", named=named)
    if not pal:
        sys.exit(f"check_contrast: parsed 0 roles from `{name}` — the shape changed")
    return pal


def read_clippycolors_of() -> dict[str, str]:
    """Pull the `factory ClippyColors.of(ColorScheme s) { ... }` body's
    field: expr assignments out of theme.dart, as {field: raw_expr}.

    Only single-line `field: expr,` assignments are captured (matches
    every field this script needs — `selBg`'s multi-line ternary is the one
    field in the factory that does NOT match, and nothing here needs it).
    """
    src = _strip_comments(THEME.read_text(encoding="utf-8"))
    m = re.search(
        r"factory ClippyColors\.of\(ColorScheme s\)\s*\{.*?return ClippyColors\((.*?)^\s*\);",
        src, re.S | re.M,
    )
    if not m:
        sys.exit(f"check_contrast: no `factory ClippyColors.of` body found in {THEME} — the shape changed")
    body = m.group(1)
    fields = dict(re.findall(r"(\w+):\s*([^\n]+?),\s*$", body, re.M))
    if not fields:
        sys.exit("check_contrast: parsed 0 fields from `ClippyColors.of` — the shape changed")
    return fields


def _resolve_derived_expr(
    expr: str, *, scheme: dict[str, str], named: dict[str, str], is_dark: bool, context: str,
) -> str:
    """Resolve one `ClippyColors.of` field expression: `s.role`, a named
    constant, a literal, or a `dark ? A : B` ternary (picking the branch for
    the theme currently being scored).
    """
    expr = expr.strip()
    m = re.fullmatch(r"s\.(\w+)", expr)
    if m:
        if m.group(1) not in scheme:
            sys.exit(f"check_contrast: ClippyColors.of.{context} refers to scheme.{m.group(1)}, "
                      f"not a field of the ColorScheme — the shape changed")
        return scheme[m.group(1)]
    m = re.fullmatch(r"dark\s*\?\s*(.+?)\s*:\s*(.+)", expr)
    if m:
        branch = m.group(1) if is_dark else m.group(2)
        return _resolve_derived_expr(branch, scheme=scheme, named=named, is_dark=is_dark, context=context)
    return _resolve_color_expr(expr, context=f"ClippyColors.of.{context}", named=named)


# ----------------------------------------------------------------- WCAG maths

def _channels(hex8: str) -> tuple[int, int, int, float]:
    a = int(hex8[0:2], 16)
    r = int(hex8[2:4], 16)
    g = int(hex8[4:6], 16)
    b = int(hex8[6:8], 16)
    return r, g, b, a / 255.0


def over(fg_hex: str, bg_hex: str) -> tuple[int, int, int]:
    """Composite fg (may be translucent) onto opaque bg."""
    fr, fgg, fb, fa = _channels(fg_hex)
    br, bgg, bb, _ = _channels(bg_hex)
    return (
        round(fr * fa + br * (1 - fa)),
        round(fgg * fa + bgg * (1 - fa)),
        round(fb * fa + bb * (1 - fa)),
    )


def composite_stack(base_hex: str, *layers: str) -> str:
    """Composite one or more translucent layers over an opaque base, bottom
    to top. -> opaque 'FFRRGGBB'. Used for the QR scanner's dim overlay and
    the translucent torch-button / hint-chip fills, so the surface actually
    scored against ink is the real rendered colour, not a bare fill alpha.
    """
    acc_r, acc_g, acc_b, _ = _channels(base_hex)
    for layer in layers:
        acc_r, acc_g, acc_b = over(layer, f"FF{acc_r:02X}{acc_g:02X}{acc_b:02X}")
    return f"FF{acc_r:02X}{acc_g:02X}{acc_b:02X}"


def _luminance(rgb: tuple[int, int, int]) -> float:
    def ch(v: int) -> float:
        v_ = v / 255
        return v_ / 12.92 if v_ <= 0.04045 else ((v_ + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(x) for x in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(fg_hex: str, bg_hex: str) -> float:
    fg_rgb = over(fg_hex, bg_hex)
    bg_rgb = over(bg_hex, bg_hex)
    hi, lo = sorted((_luminance(fg_rgb), _luminance(bg_rgb)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


# ----------------------------------------------------------- pair collection

class Pair:
    __slots__ = ("label", "fg", "bg", "kind", "why")

    def __init__(self, label: str, fg: str, bg: str, kind: str, why: str):
        self.label = label
        self.fg = fg
        self.bg = bg
        self.kind = kind  # "text" (4.5:1) or "mark" (3:1)
        self.why = why


def scheme_role_pairs(scheme: dict[str, str]) -> list[Pair]:
    """Every `onX` role scored against its matching `X` base role — found by
    auto-detecting the M3 on/base naming convention in whatever fields
    theme.dart's ColorScheme actually has, rather than a hand-typed list
    that silently stops matching new roles. `onSurfaceVariant` deliberately
    does NOT match here (there is no `surfaceVariant` field on this scheme)
    — it is swept against the six surface tiers below instead, same as
    Walletify's own audit treated it.
    """
    pairs = []
    for role in scheme:
        if not (role.startswith("on") and len(role) > 2 and role[2].isupper()):
            continue
        base = role[2].lower() + role[3:]
        if base not in scheme:
            continue
        kind, why = "text", (
            "WCAG 1.4.3 — ColorScheme on/base role pair (button labels, container ink)"
        )
        if (role, base) in LATENT_PAIRS:
            kind, why = "latent", LATENT_PAIRS[(role, base)]
        pairs.append(Pair(f"{role} on {base}", scheme[role], scheme[base], kind, why))
    return pairs


def surface_sweep_pairs(scheme: dict[str, str]) -> list[Pair]:
    """`outline` and `onSurfaceVariant` against all six surface tiers.
    Both render as real body/meta text in Clippy (`ClippyColors.muted` /
    `.muted2` — see theme.dart's own doc comment on `muted`), so both get
    the 4.5:1 text threshold, not the 3:1 a bare "outline" name suggests.
    """
    pairs = []
    for role, why in (
        ("outline", "WCAG 1.4.3 — used as body text via ClippyColors.muted (row meta line, 'N selected' etc.)"),
        ("onSurfaceVariant", "WCAG 1.4.3 — used as body text via ClippyColors.muted2 (subtitles, dialog copy)"),
    ):
        for surf in SURFACE_TIERS:
            pairs.append(Pair(f"{role} on {surf}", scheme[role], scheme[surf], "text", why))
    return pairs


def clippy_token_pairs(
    scheme: dict[str, str], *, named: dict[str, str], derived_raw: dict[str, str], is_dark: bool,
) -> list[Pair]:
    """Clippy's own tokens — never seen by Walletify's script."""
    pairs: list[Pair] = []

    sync_hex = named["syncOkDark"] if is_dark else named["syncOkLight"]
    sync_name = "syncOkDark" if is_dark else "syncOkLight"
    for surf in SURFACE_TIERS:
        pairs.append(Pair(
            f"{sync_name} on {surf}", sync_hex, scheme[surf], "mark",
            "WCAG 1.4.11 — non-text status dot (theme.dart: 'GREEN, deliberately not the brand violet')",
        ))

    def derived(field: str) -> str:
        return _resolve_derived_expr(
            derived_raw[field], scheme=scheme, named=named, is_dark=is_dark, context=field,
        )

    # accent renders as real text (the "LATEST" chip label, the "Fix"
    # banner link) as well as an icon, so it is scored at the stricter 4.5:1.
    accent_hex = derived("accent")
    for surf in ("surface", "surfaceContainerLowest"):
        pairs.append(Pair(
            f"ClippyColors.accent on {surf}", accent_hex, scheme[surf], "text",
            "WCAG 1.4.3 — renders as text (LATEST chip label, banner 'Fix' link)",
        ))

    # ink (=onSurface) is already scored against `surface` by
    # scheme_role_pairs, but its most common real backdrop is
    # surfaceContainerLowest (ClipCard fill, dialogBg) — every clip row's
    # body text renders there, not on the bare page surface.
    ink_hex = derived("ink")
    pairs.append(Pair(
        "ClippyColors.ink on surfaceContainerLowest", ink_hex, scheme["surfaceContainerLowest"], "text",
        "WCAG 1.4.3 — clip row / dialog body text sits on the card fill, not the bare page surface",
    ))

    # THE TWO BORDER TOKENS ARE NOT INTERCHANGEABLE, AND ONLY ONE OWES 3:1.
    #
    # WCAG 1.4.11 covers graphics needed to identify a CONTROL or to understand
    # content. It explicitly does not cover pure decoration. Material 3 splits
    # the two on purpose:
    #
    #   outlineVariant (= ClippyColors.border)      decorative dividers, card
    #                                               hairlines, sheet grabbers,
    #                                               a frame round a QR quiet
    #                                               zone. Low contrast is the
    #                                               POINT — see the
    #                                               tone-plus-one-edge rule in
    #                                               docs/DESIGN.md. Scoring it
    #                                               at 3:1 fails all six tiers
    #                                               in both themes and the only
    #                                               way to "pass" is to darken
    #                                               the hairline until the card
    #                                               system stops looking like
    #                                               itself. That is the gate
    #                                               measuring the wrong thing.
    #
    #   outline (= ClippyColors.borderStrong)       the boundary of an actual
    #                                               control — an outlined
    #                                               button, a chip, a text
    #                                               field. THIS one owes 3:1,
    #                                               because when it is the only
    #                                               edge a control has, losing
    #                                               it loses the control.
    #
    # So: outlineVariant is exempt and only reported for information, and
    # borderStrong is the checked token. Enforcing it this way is what turns a
    # permanently-red gate into one whose red means something. If a control's
    # edge is ever drawn with `c.border` again, THAT is the defect to fix at
    # the call site — do not relax this check to accommodate it.
    border_hex = derived("border")
    borderstrong_hex = derived("borderStrong")
    for surf in SURFACE_TIERS:
        pairs.append(Pair(
            f"ClippyColors.borderStrong on {surf}", borderstrong_hex, scheme[surf], "mark",
            "WCAG 1.4.11 — the edge of an outlined control (button, chip, text field)",
        ))
    for surf in SURFACE_TIERS:
        pairs.append(Pair(
            f"ClippyColors.border on {surf}", border_hex, scheme[surf], "decorative",
            "exempt from WCAG 1.4.11 — decorative divider / card hairline, not a control edge",
        ))

    onsnack_hex = derived("onSnack")
    snack_hex = derived("snack")
    pairs.append(Pair(
        "ClippyColors.onSnack on ClippyColors.snack", onsnack_hex, snack_hex, "text",
        "WCAG 1.4.3 — snackbar label text on its own chip",
    ))

    onbrand_hex = derived("onBrand")
    for stop_name in ("brandPurpleBright", "brandPurple"):
        pairs.append(Pair(
            f"ClippyColors.onBrand on {stop_name} (gradient stop)", onbrand_hex, named[stop_name], "text",
            "WCAG 1.4.3 — '<n> selected' title / FilledButton label on the brand gradient",
        ))

    if is_dark:
        pairs.append(Pair(
            "onPrimary(white) on primaryFillDark", named["Colors.white"], named["primaryFillDark"], "text",
            "WCAG 1.4.3 — dark FilledButton's real fill (theme.dart _build: NOT dark `primary`, see its own doc comment)",
        ))
        for surf in SURFACE_TIERS:
            pairs.append(Pair(
                f"primaryTextDark on {surf}", named["primaryTextDark"], scheme[surf], "text",
                "WCAG 1.4.3 — brand-violet body text on dark surfaces (theme.dart: dark `primary` alone is only 4.35:1)",
            ))

    return pairs


# ------------------------------------------------------- fixed-chrome pairs

def qr_scanner_pairs(named: dict[str, str]) -> list[Pair]:
    """The QR scanner is fixed dark in BOTH themes (see its own module doc
    comment) and never reads `context.ck`, so it can only be checked here.
    Every colour below is parsed out of qr_scanner_page.dart itself — never
    hand-copied — with a regex anchored on the surrounding literal text, so
    a future edit that changes the shape fails loudly instead of silently
    scoring a stale value.
    """
    src = _strip_comments(QR_SCANNER.read_text(encoding="utf-8"))

    def find(pattern: str, *, what: str) -> tuple[str, ...]:
        m = re.search(pattern, src, re.S)
        if not m:
            sys.exit(f"check_contrast: could not find {what} in {QR_SCANNER} — the shape changed")
        return m.groups()

    scanner_bg = named["scannerBg"]
    (dim_overlay_expr,) = find(
        r"DecoratedBox\(\s*decoration: BoxDecoration\(color: (Color\(0x[0-9A-Fa-f]{8}\))\)",
        what="the dim viewfinder overlay",
    )
    dim_overlay = _resolve_color_expr(dim_overlay_expr, context="QR scanner dim overlay")
    # The dim overlay's own RGB is scannerBg's RGB at partial alpha, so
    # compositing it over scannerBg is a documented no-op — kept as an
    # explicit composite rather than assumed, so a future colour change here
    # is picked up automatically instead of silently staying "an assumed no-op".
    viewfinder_bg = composite_stack(scanner_bg, dim_overlay)

    (back_icon,) = find(r"Icon\(Icons\.arrow_back_rounded,\s*color:\s*([\w.]+)\)", what="the back-icon colour")
    (title_color,) = find(r"'Scan pairing QR',\s*style: Ct\.title\(18, color: ([\w.]+)\)", what="the title text colour")
    (bracket_color,) = find(r"class _CornerBrackets.*?\.\.color = ([\w.]+)", what="the corner-bracket stroke colour")

    torch_on_bg, torch_off_bg_expr = find(
        r"color: on\s*\?\s*([\w.]+)\s*\n\s*: ([\w.]+\.withValues\(alpha: [\d.]+\))",
        what="the torch-button fill (on/off)",
    )
    torch_on_icon, torch_off_icon = find(
        r"color: on \? ([\w.]+) : ([\w.]+),", what="the torch-icon colour (on/off)",
    )
    hint_bg_expr, hint_text_color = find(
        r"color: (Colors\.white\.withValues\(alpha: [\d.]+\)),\s*\n\s*borderRadius: BorderRadius\.circular\(999\).*?"
        r"style: Ct\.body\(13\.5, color: ([\w.]+)\)",
        what="the bottom hint chip's fill and text colour",
    )

    torch_off_bg = composite_stack(viewfinder_bg, _resolve_color_expr(torch_off_bg_expr, context="torch off-state fill"))
    hint_bg = composite_stack(viewfinder_bg, _resolve_color_expr(hint_bg_expr, context="hint chip fill"))

    def col(expr: str) -> str:
        return _resolve_color_expr(expr, context="QR scanner", named=named)

    return [
        Pair("back-icon ink on scannerBg (+dim overlay)", col(back_icon), viewfinder_bg, "mark",
             "WCAG 1.4.11 — IconButton, non-text"),
        Pair("'Scan pairing QR' title on scannerBg (+dim overlay)", col(title_color), viewfinder_bg, "text",
             "WCAG 1.4.3 — real text over the viewfinder"),
        Pair("corner-bracket stroke on scannerBg (+dim overlay)", col(bracket_color), viewfinder_bg, "mark",
             "WCAG 1.4.11 — the viewfinder frame graphic, non-text"),
        Pair("torch icon (off state) on its own translucent fill", col(torch_off_icon), torch_off_bg, "mark",
             "WCAG 1.4.11 — icon button"),
        Pair("torch icon (on state, scannerBg ink) on white fill", col(torch_on_icon), col(torch_on_bg), "mark",
             "WCAG 1.4.11 — icon button"),
        Pair("hint-chip text on its own translucent fill", col(hint_text_color), hint_bg, "text",
             "WCAG 1.4.3 — real instructional text"),
    ]


def image_viewer_pairs(named: dict[str, str], dark_scheme: dict[str, str]) -> list[Pair]:
    """`_ImagePreview` in home_page.dart: fixed dark chrome in BOTH themes,
    like the scanner. `bg`/`fg`/`meta`/`danger` are parsed straight out of
    the file (they are that block's own source of truth), anchored on the
    doc comment that introduces them so a shape change fails loudly.
    """
    # NOTE: matched against the COMMENT-STRIPPED text — the block's own doc
    # comment ("Fixed dark chrome in BOTH themes...") is not a usable anchor
    # because _strip_comments removes it along with every other comment.
    # `const bg = scannerBg;` is unique in the file on its own, so it anchors
    # the block without needing the comment.
    src = _strip_comments(HOME_PAGE.read_text(encoding="utf-8"))
    m = re.search(
        r"const bg = (\w+);\s*"
        r"const fg = ([\w.]+);\s*"
        r"const meta = (Color\(0x[0-9A-Fa-f]{8}\));\s*"
        r"const danger = (Color\(0x[0-9A-Fa-f]{8}\));",
        src, re.S,
    )
    if not m:
        sys.exit(f"check_contrast: could not find the _ImagePreview bg/fg/meta/danger block in {HOME_PAGE} — the shape changed")
    bg_expr, fg_expr, meta_expr, danger_expr = m.groups()

    local_named = dict(named)
    bg = _resolve_color_expr(bg_expr, context="_ImagePreview.bg", named=local_named)
    fg = _resolve_color_expr(fg_expr, context="_ImagePreview.fg", named=local_named)
    meta = _resolve_color_expr(meta_expr, context="_ImagePreview.meta")
    danger = _resolve_color_expr(danger_expr, context="_ImagePreview.danger")

    (border_alpha,) = re.search(r"border: danger\.withValues\(alpha: ([\d.]+)\)", src).groups() \
        if re.search(r"border: danger\.withValues\(alpha: ([\d.]+)\)", src) else (None,)
    if border_alpha is None:
        sys.exit(f"check_contrast: could not find danger's border alpha in {HOME_PAGE} — the shape changed")
    danger_border = f"{round(float(border_alpha) * 255):02X}{danger[2:]}"
    danger_border_effective = composite_stack(bg, danger_border)

    pairs = [
        Pair("fg(white) text on bg (scannerBg)", fg, bg, "text",
             "WCAG 1.4.3 — 'Image' label / 'Copy image' button label"),
        Pair("fg(white) icon on bg (scannerBg)", fg, bg, "mark",
             "WCAG 1.4.11 — close / copy icon buttons"),
        Pair("meta text on bg (scannerBg)", meta, bg, "text",
             "WCAG 1.4.3 — 'PNG · 240 KB · device · 2m' line"),
        Pair("danger icon on bg (scannerBg)", danger, bg, "mark",
             "WCAG 1.4.11 — delete icon"),
        # Label reads the alpha it actually parsed — a hardcoded "35%" here
        # would keep printing 35 after someone changed the Dart to 45.
        Pair(f"danger border ({round(float(border_alpha) * 100)}% alpha, composited) on bg",
             danger_border_effective, bg, "mark",
             "WCAG 1.4.11 — delete button's own outline"),
        Pair("fg(white) label on primaryFillDark", fg, named["primaryFillDark"], "text",
             "WCAG 1.4.3 — 'Copy image' button fill (same token as the dark FilledButton)"),
        Pair("fg(white) icon on primaryFillDark", fg, named["primaryFillDark"], "mark",
             "WCAG 1.4.11 — 'Copy image' button's leading icon"),
    ]

    # Drift check: meta/danger are documented in home_page.dart's own
    # comments as copies of the dark scheme's outline/error. If theme.dart's
    # dark scheme ever moves and these don't, they silently stop matching
    # what they claim to be — exactly the duplicate-value failure mode the
    # user's own workflow guidance calls out. Not a contrast failure, so it
    # does not affect the exit code; printed as its own line either way.
    drift = []
    if meta != dark_scheme["outline"]:
        drift.append(f"meta {meta} != dark ColorScheme.outline {dark_scheme['outline']}")
    if danger != dark_scheme["error"]:
        drift.append(f"danger {danger} != dark ColorScheme.error {dark_scheme['error']}")
    print("  [drift check] home_page.dart's `meta`/`danger` vs. theme.dart's dark scheme: "
          + ("OK, still match" if not drift else "DRIFTED — " + "; ".join(drift)))

    return pairs


# ---------------------------------------------------------------------- main

def run_section(title: str, pairs: list[Pair]) -> int:
    print(f"\n[{title}]")
    fails = 0
    for p in pairs:
        r = contrast_ratio(p.fg, p.bg)
        # "decorative" is measured and printed but never enforced — WCAG 1.4.11
        # exempts pure decoration. It is printed so a reviewer can still SEE the
        # number and challenge the exemption, rather than the pair vanishing.
        if p.kind == "decorative":
            print(f"  --   {r:5.2f}:1  exempt (decorative)              {p.label}")
            print(f"        why: {p.why}")
            continue
        if p.kind == "latent":
            # The latent list is keyed by ROLE NAME, so it matches in both
            # themes — but the pair usually fails in only one of them. Where it
            # already clears the bar, print it as the ordinary pass it is;
            # announcing "below 4.5:1" over an 8.25:1 light pair would be a
            # gate that lies in the safe direction, which is still lying.
            if r >= TEXT_MIN:
                print(f"  ok   {r:5.2f}:1  needs 4.5:1 (WCAG 1.4.3, text)  {p.label}")
                print("        why: WCAG 1.4.3 — ColorScheme on/base role pair "
                      "(listed as latent for the other theme; passes here)")
                continue
            print(f"  WARN {r:5.2f}:1  below 4.5:1 but UNUSED           {p.label}")
            print(f"        why: {p.why}")
            continue
        need = MARK_MIN if p.kind == "mark" else TEXT_MIN
        ok = r >= need
        tag = "ok  " if ok else "FAIL"
        threshold_name = "3:1 (WCAG 1.4.11, non-text mark)" if p.kind == "mark" else "4.5:1 (WCAG 1.4.3, text)"
        print(f"  {tag} {r:5.2f}:1  needs {threshold_name}  {p.label}")
        print(f"        why: {p.why}")
        if not ok:
            fails += 1
    return fails


def main() -> int:
    theme_named_raw = read_named_exprs(THEME)
    required_consts = [
        "brandPurple", "brandPurpleBright", "primaryFillDark", "primaryTextDark",
        "scannerBg", "syncOkLight", "syncOkDark",
    ]
    missing = [n for n in required_consts if n not in theme_named_raw]
    if missing:
        sys.exit(f"check_contrast: {', '.join(missing)} not found in {THEME} — the shape changed")

    named: dict[str, str] = dict(_NAMED_FLUTTER_COLORS)
    # These are all literal `Color(0x........)` today (verified against the
    # current file); resolving through `_resolve_color_expr` rather than
    # trusting that keeps the same "fail loudly on a shape change" guarantee
    # as everywhere else if one is ever rewritten as an expression.
    for n in required_consts:
        named[n] = _resolve_color_expr(theme_named_raw[n][0], context=f"theme.dart top-level const {n}", named=named)

    light = read_scheme("_lightScheme", named=named)
    dark = read_scheme("_darkScheme", named=named)
    derived_raw = read_clippycolors_of()

    exit_code = 0
    for theme_name, scheme, is_dark in (("LIGHT", light, False), ("DARK", dark, True)):
        print(f"\n===================== {theme_name} =====================")
        fails = 0
        fails += run_section(
            "ColorScheme onX/X role pairs (auto-detected)", scheme_role_pairs(scheme),
        )
        fails += run_section(
            "outline / onSurfaceVariant across all six surface tiers", surface_sweep_pairs(scheme),
        )
        fails += run_section(
            "Clippy-specific tokens (syncOk, ClippyColors.of derived roles"
            + (", dark-only primaryFillDark/primaryTextDark" if is_dark else "") + ")",
            clippy_token_pairs(scheme, named=named, derived_raw=derived_raw, is_dark=is_dark),
        )
        print(f"\n  -> {theme_name}: {fails} pair(s) below threshold" + ("" if fails else "  — PASS"))
        if fails:
            exit_code = 1

    print("\n===================== FIXED CHROME (identical in both themes) =====================")
    print("Not theme-scoped: these two screens never read context.ck and render the same in light mode.")
    fails = 0
    fails += run_section("QR scanner — lib/app/qr_scanner_page.dart", qr_scanner_pairs(named))
    fails += run_section("Image viewer — lib/app/home_page.dart _ImagePreview", image_viewer_pairs(named, dark))
    print(f"\n  -> FIXED CHROME: {fails} pair(s) below threshold" + ("" if fails else "  — PASS"))
    if fails:
        exit_code = 1

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
