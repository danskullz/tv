#!/usr/bin/env python3
"""
Shoal -- app icon generator.

Theme: ocean. A school of fish moving through deep water, lit from the surface.
The letterform is the 'S' from Helvetica Neue Bold (a real outline, not a
hand-drawn path), filled with flat-shaded low-poly facets on an ocean ramp.
Facet brightness follows a smooth "current" field -- a diagonal key light plus
a surface gradient, lightly modulated -- so the facets read as light moving
through water rather than as random confetti. Background is near-black water.

Everything renders inside a <clipPath> of the glyph, so no polygon-clipping
maths is needed -- the renderer does it exactly.

Outputs icon-shoal.svg, a self-contained icon-shoal.html review page, and
(optionally) a PNG iconset.
"""

import argparse
import math
import random
import re
import subprocess
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTCollection

ART = 1024.0          # artboard size (macOS icon convention)
GLYPH_H = 690.0       # height of the S in artboard units
CELL = 320.0          # low-poly lattice cell size -- deliberately coarse
JITTER = 0.24         # vertex jitter, as a fraction of the cell

# The glyph only covers part of the artboard, so current() spans roughly
# 0.28-0.61 across it. Expanding that window to TONE_LO..TONE_HI makes the S
# use the full ramp instead of sitting in its darkest third.
TONE_LO, TONE_HI = 0.17, 0.78

FONT_PATH = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_INDEX = 1        # Helvetica Neue Bold

HERE = Path(__file__).parent


# --------------------------------------------------------------------------- #
# Letterform
# --------------------------------------------------------------------------- #
def glyph_path() -> str:
    """Return the 'S' outline as an SVG path baked into artboard coordinates."""
    font = TTCollection(FONT_PATH).fonts[FONT_INDEX]
    glyph_set = font.getGlyphSet()
    glyph = glyph_set[font.getBestCmap()[ord("S")]]

    pen = BoundsPen(glyph_set)
    glyph.draw(pen)
    x_min, y_min, x_max, y_max = pen.bounds

    scale = GLYPH_H / (y_max - y_min)
    tx = ART / 2 - scale * (x_min + x_max) / 2
    ty = ART / 2 + scale * (y_min + y_max) / 2

    svg_pen = SVGPathPen(glyph_set)
    glyph.draw(TransformPen(svg_pen, (scale, 0, 0, -scale, tx, ty)))
    return svg_pen.getCommands()


# --------------------------------------------------------------------------- #
# Facet field
# --------------------------------------------------------------------------- #
def lattice(seed: int = 20261011):
    """A jittered triangular lattice covering the artboard, as (triangle, noise)."""
    rng = random.Random(seed)
    cols = int(ART / CELL) + 2
    rows = int(ART / CELL) + 2

    pts = {}
    for r in range(-2, rows + 2):
        for c in range(-2, cols + 2):
            base_x = c * CELL + (CELL / 2 if r % 2 else 0)
            base_y = r * CELL
            pts[(r, c)] = (
                base_x + rng.uniform(-1, 1) * CELL * JITTER,
                base_y + rng.uniform(-1, 1) * CELL * JITTER,
            )

    for r in range(-1, rows):
        for c in range(-1, cols):
            a, b = pts[(r, c)], pts[(r, c + 1)]
            d, e = pts[(r + 1, c + 1)], pts[(r + 1, c)]
            # Alternate the diagonal so the facets read as a triangular mesh.
            tris = [(a, b, d), (a, d, e)] if (r + c) % 2 == 0 else [(a, b, e), (b, d, e)]
            for tri in tris:
                yield tri, rng.uniform(-1.0, 1.0)


def current(x: float, y: float) -> float:
    """Light level at a point, 0 = abyss, 1 = foam. Smooth and periodic.

    The key light dominates; the sine terms only modulate it, so the shading
    always reads as light coming from the top-left.
    """
    u, v = x / ART, y / ART
    return (
        0.44 * (1 - v)                      # light from the surface, top-down
        + 0.40 * (1 - u * 0.62 - v * 0.38)  # key light from the top-left
        + 0.055 * math.sin(u * 9.5 + v * 3.0)
        + 0.030 * math.sin(v * 11.0 - u * 2.0)
    )


# Ocean ramp: abyss navy -> deep -> midwater -> teal shallows. Seven stops,
# so adjacent shards land on clearly different shades. The top stop stays a
# saturated aqua rather than foam white, to keep the blues reading as blues.
RAMP = [
    (9, 34, 57),
    (13, 71, 113),
    (18, 126, 174),
    (28, 162, 191),
    (58, 200, 199),
    (120, 226, 212),
    (176, 240, 228),
]


def ramp_color(t: float) -> str:
    t = min(1.0, max(0.0, t))
    pos = t * (len(RAMP) - 1)
    i = int(pos)
    if i >= len(RAMP) - 1:
        r, g, b = RAMP[-1]
    else:
        f = pos - i
        c0, c1 = RAMP[i], RAMP[i + 1]
        r = round(c0[0] + (c1[0] - c0[0]) * f)
        g = round(c0[1] + (c1[1] - c0[1]) * f)
        b = round(c0[2] + (c1[2] - c0[2]) * f)
    return f"#{r:02x}{g:02x}{b:02x}"


def facet_fill(tri, noise: float) -> str:
    cx = sum(p[0] for p in tri) / 3
    cy = sum(p[1] for p in tri) / 3
    tone = (current(cx, cy) + noise * 0.055 - TONE_LO) / (TONE_HI - TONE_LO)
    return ramp_color(tone)


def fmt(p) -> str:
    return " ".join(f"{v:.1f}" for v in p)


def transform_path(d, s=1.0, tx=0.0, ty=0.0):
    """Scale and translate a path written in absolute coordinates.

    Safe for what SVGPathPen emits (M/C/Z, all absolute). Every command there
    takes an even number of coordinates, so a running parity counter maps each
    x,y pair correctly without having to parse commands properly.
    """
    out, i = [], 0
    for tok in re.findall(r"[A-Za-z]|-?\d*\.?\d+(?:[eE]-?\d+)?", d):
        if tok.isalpha():
            out.append(tok)
        else:
            v = float(tok)
            out.append(f"{v * s + (tx if i % 2 == 0 else ty):.1f}")
            i += 1
    # Space-separated, not concatenated: without the separators "M 512 305"
    # re-emits as "M512.0305", which parses as a single number.
    return " ".join(out)


# --------------------------------------------------------------------------- #
# Ocean backdrop
# --------------------------------------------------------------------------- #
# Flat bands of water washing up from the bottom of the frame, each with its own
# crest line. Listed highest crest first: every band fills from its own crest
# down to the bottom edge, so the one drawn last is the one you see lowest.
# This is the whole mark -- there is nothing else in the frame.
# (resting height, crest amplitude, wavelength, phase, fill)
WAVES = [
    (596, 28, 760, 3.05, "#2f93b8"),
    (676, 24, 880, 0.90, "#1d76a2"),
    (758, 21, 1010, 4.05, "#155d8c"),
    (846, 18, 1160, 2.10, "#104874"),
    (938, 15, 1340, 0.35, "#0c375c"),
]


def crest(y0, amp, wl, phase, x):
    """Height of one wave band at a point across the frame."""
    return (y0
            + amp * math.sin(2 * math.pi * x / wl + phase)
            + amp * 0.38 * math.sin(2 * math.pi * x / (wl * 0.43) + phase * 1.7))


def wave_backdrop():
    bands = []
    for y0, amp, wl, phase, color in WAVES:
        pts = " ".join(
            f"{ART * i / 64:.1f},{crest(y0, amp, wl, phase, ART * i / 64):.1f}"
            for i in range(65)
        )
        bands.append(
            f'<path d="M{pts} L{ART:.0f},{ART:.0f} L0,{ART:.0f} Z" fill="{color}"/>'
        )
    return "\n      ".join(bands)


# --------------------------------------------------------------------------- #
# SVG
# --------------------------------------------------------------------------- #
def art(path_d: str | list[str] | None = None, overlays: str = "", over: str = "",
        pad_ratio: float = 0.0, uid: str = "", waves: bool = True) -> str:
    """Render the icon's contents (defs + body), with no <svg> wrapper.

    The mark is the wave bands alone. Everything else is optional:

    path_d    a silhouette for the faceted fill to sit in -- None, the default,
             leaves the frame holding nothing but water. Pass a list to union
             several outlines (they must all wind the same way).
    overlays  markup painted inside the silhouette (eyes, ridges, ...).
    over      markup painted inside the frame but outside the silhouette.
    pad_ratio insets the squircle (0 = full bleed).
    uid       suffix for every element id. Needed when several icons share one
             document (as <symbol>s on a review page): ids must be unique or
             every <use> resolves to whichever definition came first.
    waves     draw the layered ocean backdrop.
    """
    outlines = [] if path_d is None else ([path_d] if isinstance(path_d, str) else list(path_d))
    frame, letter, bg, rim = (f"{n}{uid}" for n in ("frame", "letter", "bg", "rim"))

    # A clipPath's children are unioned by fill rule, not by a real boolean:
    # overlapping subpaths only survive if they all wind the same way, so they
    # are combined into one compound path under `nonzero`.
    clip_d = "".join(outlines)
    clip = "".join(f'\n      <path d="{d}"/>' for d in outlines)

    if outlines:
        facets = []
        for tri, noise in lattice():
            facets.append(
                f'<polygon points="{fmt(tri[0])} {fmt(tri[1])} {fmt(tri[2])}" '
                f'fill="{facet_fill(tri, noise)}"/>'
            )
        facets = "\n      ".join("      " + f for f in facets)
        letter_defs = f'''
    <clipPath id="{letter}" clipPathUnits="userSpaceOnUse">
      <path clip-rule="nonzero" d="{clip_d}"/>
    </clipPath>'''
        # Rim under the facets: the fill then covers the half that lies inside
        # the silhouette, so only the outer edge catches light. Drawing it on top
        # would also stroke the seams where the union's parts overlap.
        rim_markup = (f'\n    <g fill="none" stroke="url(#{rim})" stroke-width="9" '
                      f'stroke-linejoin="round">{clip}\n    </g>')
        body = f'''
    {rim_markup}

    <g clip-path="url(#{letter})">
      {facets}
      {overlays}
    </g>
{over}'''
    else:
        facets = ""
        letter_defs = ""
        rim_markup = ""
        body = f"\n{over}" if over else ""

    # The macOS squircle, as a superellipse. Apple's own mask is proprietary;
    # this is the standard n=5 approximation, which is visually identical.
    n, r = 5.0, 512.0 * (1 - pad_ratio)
    c = ART / 2

    def squircle():
        steps = 512
        pts = []
        for i in range(steps):
            t = 2 * math.pi * i / steps
            ct, st = math.cos(t), math.sin(t)
            x = c + r * math.copysign(abs(ct) ** (2 / n), ct)
            y = c + r * math.copysign(abs(st) ** (2 / n), st)
            pts.append(f"{x:.2f},{y:.2f}")
        return "M" + "L".join(pts) + "Z"

    return f"""<defs>
    <clipPath id="{frame}" clipPathUnits="userSpaceOnUse">
      <path d="{squircle()}"/>
    </clipPath>{letter_defs}

    <!-- Deep water: near-black -->
    <radialGradient id="{bg}" cx="30%" cy="14%" r="96%">
      <stop offset="0%"   stop-color="#111f2b"/>
      <stop offset="50%"  stop-color="#070d13"/>
      <stop offset="100%" stop-color="#020406"/>
    </radialGradient>

    <!-- Light raking the upper-left edge of the silhouette -->
    <linearGradient id="{rim}" gradientUnits="userSpaceOnUse" x1="200" y1="200" x2="800" y2="850">
      <stop offset="0%"   stop-color="#bff0e8" stop-opacity="0.55"/>
      <stop offset="35%"  stop-color="#8fd8e0" stop-opacity="0.12"/>
      <stop offset="100%" stop-color="#8fd8e0" stop-opacity="0"/>
    </linearGradient>
  </defs>

  <g clip-path="url(#{frame})">
    <rect width="{ART:.0f}" height="{ART:.0f}" fill="url(#{bg})"/>
{body}
    {'      ' + wave_backdrop() if waves else ''}
  </g>"""


# Where the S sits when it is standing in the water: scaled down and raised, so
# its foot is submerged at the waterline (~y 596) rather than half drowned.
SURF_SCALE = 0.87
SURF_CENTER_Y = 370


def surf_path():
    """The S, rescaled and lifted to sit in the wave backdrop."""
    s = SURF_SCALE
    return transform_path(glyph_path(), s, ART / 2 - s * ART / 2, SURF_CENTER_Y - s * ART / 2)


def build(pad_ratio: float = 0.0, letter: bool = False) -> str:
    """The icon as a standalone SVG file. Waves only unless `letter`."""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {ART:.0f} {ART:.0f}" '
        f'width="{ART:.0f}" height="{ART:.0f}">\n'
        + art(path_d=surf_path() if letter else None, pad_ratio=pad_ratio) + "\n</svg>\n"
    )


# --------------------------------------------------------------------------- #
# Review page
# --------------------------------------------------------------------------- #
def build_html(body: str, letter: bool = False) -> str:
    """A self-contained review page.

    The art is defined once as a <symbol> and instanced with <use>, so the page
    stays small no matter how many sizes it shows.
    """
    swatches = "".join(
        f'<div style="background:{c}">{c}</div>' for c in (w[4] for w in WAVES)
    )
    subtitle = (
        "Ocean &mdash; layered water washing up from the bottom, over near-black.<br>"
        "Five flat bands, each with its own crest line. Nothing else in the frame."
        if not letter else
        "Ocean &mdash; the faceted S standing in the water (the letter is optional)."
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shoal &mdash; icon</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 56px 32px 96px;
    background: #16181c; color: #e9edf3;
    font: 14px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    display: flex; flex-direction: column; align-items: center; gap: 32px;
  }}
  h1 {{ font-size: 22px; font-weight: 600; margin: 0; letter-spacing: -0.015em; }}
  .sub {{ color: #8b95a3; margin: -22px 0 0; font-size: 13px; text-align: center; }}
  h2 {{
    font-size: 11px; font-weight: 600; letter-spacing: 0.09em; text-transform: uppercase;
    color: #7d8794; margin: 0 0 16px;
  }}
  .panel {{
    background: #1e2127; border: 1px solid #2b2f37; border-radius: 16px;
    padding: 30px 34px; width: 100%; max-width: 1000px;
  }}
  .hero {{ display: flex; justify-content: center; padding: 6px 0 2px; }}
  /* One art instance, sized by the --s custom property on its container. */
  .art {{ display: block; width: var(--s, 128px); height: var(--s, 128px); }}

  .ladder {{ display: flex; gap: 26px; align-items: flex-end; flex-wrap: wrap; }}
  .cell {{ display: flex; flex-direction: column; align-items: center; gap: 10px; }}
  .cell span {{ font-size: 11px; color: #6f7885; font-variant-numeric: tabular-nums; }}

  .contexts {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 14px; }}
  .ctx {{ border-radius: 14px; padding: 22px; display: flex; gap: 16px;
          align-items: center; font-size: 12.5px; line-height: 1.4; }}
  .ctx.dark  {{ background: #0b0d10; border: 1px solid #262a31; }}
  .ctx.light {{ background: #eef1f5; color: #1b1f25; border: 1px solid #dde2e9; }}
  .ctx.dock  {{ background: linear-gradient(#454c58, #232830); border: 1px solid #515865; }}
  .ctx b {{ font-weight: 600; }}
  .ctx em {{ font-style: normal; color: #8b95a3; }}
  .ctx.light em {{ color: #6b7683; }}

  .swatches {{ display: flex; width: 100%; border-radius: 10px; overflow: hidden; }}
  .swatches div {{
    flex: 1 1 0; height: 56px; display: flex; align-items: flex-end; padding: 7px 8px;
    font-size: 10px; color: rgba(255,255,255,.7);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }}
</style>
</head>
<body>
  <!-- The art, defined once. -->
  <svg width="0" height="0" style="position:absolute" aria-hidden="true">
    <symbol id="icon-art" viewBox="0 0 {ART:.0f} {ART:.0f}">{body}</symbol>
  </svg>

  <h1>Shoal</h1>
  <p class="sub">{subtitle}</p>

  <div class="panel">
    <div class="hero" style="--s:400px">
      <svg class="art"><use href="#icon-art"/></svg>
    </div>
  </div>

  <div class="panel">
    <h2>Size ladder &mdash; actual pixels</h2>
    <div class="ladder">
      <div class="cell" style="--s:16px"><svg class="art"><use href="#icon-art"/></svg><span>16</span></div>
      <div class="cell" style="--s:32px"><svg class="art"><use href="#icon-art"/></svg><span>32</span></div>
      <div class="cell" style="--s:64px"><svg class="art"><use href="#icon-art"/></svg><span>64</span></div>
      <div class="cell" style="--s:128px"><svg class="art"><use href="#icon-art"/></svg><span>128</span></div>
      <div class="cell" style="--s:256px"><svg class="art"><use href="#icon-art"/></svg><span>256</span></div>
    </div>
  </div>

  <div class="panel">
    <h2>In context &mdash; 48px</h2>
    <div class="contexts">
      <div class="ctx dark"><svg class="art" style="--s:48px"><use href="#icon-art"/></svg>
        <span><b>Desktop</b><br><em>dark wallpaper</em></span></div>
      <div class="ctx light"><svg class="art" style="--s:48px"><use href="#icon-art"/></svg>
        <span><b>Desktop</b><br><em>light wallpaper</em></span></div>
      <div class="ctx dock"><svg class="art" style="--s:48px"><use href="#icon-art"/></svg>
        <span><b>Dock</b><br><em>translucent</em></span></div>
    </div>
  </div>

  <div class="panel">
    <h2>Water, surface to deep</h2>
    <div class="swatches">{swatches}</div>
  </div>
</body>
</html>
"""


def render_pngs(svg_path: Path, sizes) -> None:
    """Rasterise a PNG set. Names follow the SVG, so the surf variant and the
    plain one don't overwrite each other's rasters."""
    stem = svg_path.stem
    out_dir = svg_path.parent / f"{stem}-iconset"
    out_dir.mkdir(exist_ok=True)
    for size in sizes:
        target = svg_path.parent / f"{stem}.png" if size == 1024 else out_dir / f"icon_{size}.png"
        subprocess.run(
            ["rsvg-convert", "-w", str(size), "-h", str(size), str(svg_path), "-o", str(target)],
            check=True,
        )
        print("wrote", target)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--png", action="store_true", help="also rasterise a PNG set")
    ap.add_argument("--pad", type=float, default=0.0, help="inset the squircle, e.g. 0.06")
    ap.add_argument("--letter", action="store_true",
                    help="put the faceted S in the water; by default the frame "
                         "holds nothing but the waves")
    args = ap.parse_args()

    body = art(path_d=surf_path() if args.letter else None, pad_ratio=args.pad)

    suffix = "-letter" if args.letter else ""
    svg_out = HERE / f"icon-shoal{suffix}.svg"
    svg_out.write_text(build(pad_ratio=args.pad, letter=args.letter))
    print(f"wrote {svg_out}")

    html_out = HERE / f"icon-shoal{suffix}.html"
    html_out.write_text(build_html(body, args.letter))
    print(f"wrote", html_out)

    if args.png:
        render_pngs(svg_out, [16, 32, 64, 128, 256, 512, 1024])
