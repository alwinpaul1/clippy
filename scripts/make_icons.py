"""Render Clippy's launcher assets straight from vector. No colour keying.

Every earlier icon went through a flat PNG and a purple colour key, which cost
three separate repairs: white corner notches, an antialiased ring the key kept,
and faint specks that shrank the mark. None of that can happen here, because
each layer is DRAWN rather than extracted.

The four assets are genuinely different images, not crops of one:

  clippy_icon_1024        full design, border included (Android legacy, Windows)
  clippy_background_1024  flat purple, the adaptive BACKGROUND layer
  clippy_foreground_1024  the mark ONLY, inset, no border  <- see note
  clippy_icon_macos_1024  full design in the macOS rounded-rect proportion

The border ring is deliberately ABSENT from the adaptive foreground. Android
applies its own mask (circle, squircle, teardrop, per OEM) and a decorative
rounded-rect border underneath that mask lands as a clipped arc floating in the
corners. The ring belongs to the square icon, not the masked one.

Geometry comes from `ClippyMark` in lib/app/theme.dart, so the launcher icon and
the mark drawn inside the app are the same artwork.

Border numbers (inset 51, radius 200, 28 stroke) came from Grok, which was asked
for a second opinion on this icon; its ring was better than the one written here
first. Its paperclip was not usable, so only the ring was taken.
"""
import subprocess
import sys
from pathlib import Path

OUT = Path(sys.argv[1])
S = 1024
PURPLE = "#7C3AED"
BORDER_STROKE = 22  # 28 read heavy once the mark sat inside it

CLIP = ("M18,24 V58 A12,12 0 0 0 42,58 V18 A8,8 0 0 0 26,18 V56 "
        "A4,4 0 0 0 34,56 V26")


def mark_svg(stroke=7.0, eye_r=7.5, pupil_r=3.4) -> str:
    eyes = "".join(
        f'<circle cx="{cx}" cy="8" r="{eye_r}" fill="#fff"/>'
        f'<circle cx="{cx + 1.5}" cy="9" r="{pupil_r}" fill="{PURPLE}"/>'
        for cx in (24.0, 38.0)
    )
    brows = (f'<path d="M15,-1 Q20,-5 26,-2" fill="none" stroke="#fff" '
             f'stroke-width="{stroke * 0.62}" stroke-linecap="round"/>'
             f'<path d="M36,-2 Q42,-5 47,-1" fill="none" stroke="#fff" '
             f'stroke-width="{stroke * 0.62}" stroke-linecap="round"/>')
    return (f'<path d="{CLIP}" fill="none" stroke="#fff" stroke-width="{stroke}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>{eyes}{brows}')


def framed(mark_fraction: float, border: bool, bg: bool = True) -> str:
    """The mark placed on the canvas. `mark_fraction` is its height."""
    vb_w, vb_h = 36, 84          # y reaches 76: the bottom arc plus its stroke
    art_h = S * mark_fraction
    art_w = art_h * vb_w / vb_h
    ring = ("" if not border else
            f'<rect x="51" y="51" width="922" height="922" rx="200" '
            f'fill="none" stroke="#fff" stroke-width="{BORDER_STROKE}"/>')
    back = f'<rect width="{S}" height="{S}" fill="{PURPLE}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
            f'viewBox="0 0 {S} {S}">{back}{ring}'
            f'<svg x="{(S - art_w) / 2:.1f}" y="{(S - art_h) / 2:.1f}" '
            f'width="{art_w:.1f}" height="{art_h:.1f}" '
            f'viewBox="12 -8 {vb_w} {vb_h}">{mark_svg()}</svg></svg>')


def macos() -> str:
    art = int(S * 0.805)          # the platform's own proportion
    inner = framed(0.62, border=True)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
            f'viewBox="0 0 {S} {S}">'
            f'<defs><clipPath id="r"><rect x="{(S-art)//2}" y="{(S-art)//2}" '
            f'width="{art}" height="{art}" rx="{int(art*0.225)}"/></clipPath></defs>'
            f'<g clip-path="url(#r)">'
            f'<svg x="{(S-art)//2}" y="{(S-art)//2}" width="{art}" height="{art}" '
            f'viewBox="0 0 {S} {S}">{inner[inner.index(">")+1:]}</g></svg>')


ASSETS = {
    # Legacy Android + Windows: the full square, border included.
    "clippy_icon_1024": framed(0.62, border=True),
    # Adaptive background: flat colour, nothing else.
    "clippy_background_1024": (f'<svg xmlns="http://www.w3.org/2000/svg" '
                               f'width="{S}" height="{S}">'
                               f'<rect width="{S}" height="{S}" fill="{PURPLE}"/></svg>'),
    # Adaptive foreground: mark only, transparent, inside the safe zone.
    "clippy_foreground_1024": framed(0.58, border=False, bg=False),
    "clippy_icon_macos_1024": macos(),
}

OUT.mkdir(parents=True, exist_ok=True)
for name, doc in ASSETS.items():
    svg = OUT / f"{name}.svg"
    png = OUT / f"{name}.png"
    svg.write_text(doc, encoding="utf-8")
    subprocess.run(["rsvg-convert", "-w", str(S), "-h", str(S),
                    "-o", str(png), str(svg)], check=True)
    print(f"wrote {png.name}")
