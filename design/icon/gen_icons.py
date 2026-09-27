#!/usr/bin/env python3
"""Generates the den app icon SVGs (hand-built vector, no deps).

Usage: python3 design/icon/gen_icons.py   -> writes concept-*.svg + den-icon.svg next to this file.
Canvas follows the macOS icon grid: 1024 canvas, 824 squircle body at offset 100.
"""
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent
C, BODY, OFF = 1024, 824, 100


def squircle(n: float = 5.0, steps: int = 720) -> str:
    """Superellipse |x|^n + |y|^n = 1, close to Apple's continuous-corner icon shape."""
    r = BODY / 2
    cx = cy = OFF + r
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + r * math.copysign(abs(ct) ** (2 / n), ct)
        y = cy + r * math.copysign(abs(st) ** (2 / n), st)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


SQ = squircle()


def arch(cx: float, base: float, w: float, top: float) -> str:
    """Upright round-top arch (door/cave mouth) with a flat base."""
    r = w / 2
    return (f"M{cx - r:.1f},{base:.1f} L{cx - r:.1f},{top + r:.1f} "
            f"A{r:.1f},{r:.1f} 0 0 1 {cx + r:.1f},{top + r:.1f} "
            f"L{cx + r:.1f},{base:.1f} Z")


def frame(defs: str, body: str, title: str) -> str:
    """Shared shell: drop shadow, clipped body, glass rim highlight."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {C} {C}" width="{C}" height="{C}">
  <title>{title}</title>
  <defs>
    <clipPath id="sq"><path d="{SQ}"/></clipPath>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="14"/>
    </filter>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="22"/>
    </filter>
    <filter id="softer" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="46"/>
    </filter>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity=".38"/>
      <stop offset=".18" stop-color="#fff" stop-opacity=".06"/>
      <stop offset=".8" stop-color="#fff" stop-opacity="0"/>
      <stop offset="1" stop-color="#fff" stop-opacity=".10"/>
    </linearGradient>
{defs}
  </defs>
  <path d="{SQ}" fill="#000" opacity=".28" transform="translate(0 12)" filter="url(#shadow)"/>
  <g clip-path="url(#sq)">
{body}
  </g>
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="5"/>
</svg>
"""


# ---------- Concept A: Hearth Arch — a glowing den door crowned by a mane of arches ----------
def concept_a() -> str:
    cx, base = 512, 790
    defs = """    <linearGradient id="bgA" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3a2230"/>
      <stop offset="1" stop-color="#170d14"/>
    </linearGradient>
    <linearGradient id="m1" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#f2b15a"/><stop offset="1" stop-color="#b8582a"/>
    </linearGradient>
    <linearGradient id="m2" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#d9803c"/><stop offset="1" stop-color="#8a3a22"/>
    </linearGradient>
    <linearGradient id="m3" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#a34a2a"/><stop offset="1" stop-color="#5a2420"/>
    </linearGradient>
    <radialGradient id="glowA" cx=".5" cy=".92" r=".9">
      <stop offset="0" stop-color="#fff4d6"/>
      <stop offset=".35" stop-color="#ffc56b"/>
      <stop offset="1" stop-color="#e0772f"/>
    </radialGradient>"""
    body = f"""    <rect width="{C}" height="{C}" fill="url(#bgA)"/>
    <ellipse cx="{cx}" cy="{base}" rx="330" ry="120" fill="#ff9a3c" opacity=".35" filter="url(#softer)"/>
    <path d="{arch(cx, base, 560, 236)}" fill="url(#m3)"/>
    <path d="{arch(cx, base, 460, 296)}" fill="url(#m2)"/>
    <path d="{arch(cx, base, 360, 356)}" fill="url(#m1)"/>
    <path d="{arch(cx, base, 250, 426)}" fill="#1c0f14"/>
    <path d="{arch(cx, base, 210, 452)}" fill="url(#glowA)"/>
    <rect x="0" y="{base}" width="{C}" height="{C - base}" fill="#120a0f"/>
    <rect x="0" y="{base}" width="{C}" height="3" fill="#ffcf8a" opacity=".35"/>"""
    return frame(defs, body, "den — concept A: hearth arch")


# ---------- Concept B: Lettermark — a lowercase d whose bowl is the lit den ----------
def concept_b() -> str:
    defs = """    <linearGradient id="bgB" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f3dcb2"/>
      <stop offset="1" stop-color="#d9a864"/>
    </linearGradient>
    <linearGradient id="stone" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5a3423"/><stop offset="1" stop-color="#2e1a14"/>
    </linearGradient>
    <radialGradient id="glowB" cx=".5" cy=".95" r=".85">
      <stop offset="0" stop-color="#fff1cf"/>
      <stop offset=".45" stop-color="#ffb54c"/>
      <stop offset="1" stop-color="#c8561f"/>
    </radialGradient>"""
    # bowl: round-top arch; stem: tall bar on the right, both in dark stone
    bowl_cx, base = 468, 770
    body = f"""    <rect width="{C}" height="{C}" fill="url(#bgB)"/>
    <ellipse cx="512" cy="300" rx="420" ry="220" fill="#fff" opacity=".25" filter="url(#softer)"/>
    <path d="{arch(bowl_cx, base, 400, 360)}" fill="url(#stone)"/>
    <rect x="608" y="236" width="118" height="{base - 236}" rx="59" fill="url(#stone)"/>
    <rect x="608" y="{base - 118}" width="118" height="118" fill="url(#stone)"/>
    <path d="{arch(bowl_cx, base, 268, 440)}" fill="url(#glowB)"/>
    <ellipse cx="{bowl_cx}" cy="{base}" rx="190" ry="40" fill="#ffb54c" opacity=".55" filter="url(#soft)"/>
    <rect x="0" y="{base}" width="{C}" height="{C - base}" fill="#b98449"/>"""
    return frame(defs, body, "den — concept B: d lettermark")


# ---------- Concept C: Mane Sun — rounded mane rays around a dark hollow with an ember ----------
def concept_c() -> str:
    cx, cy = 512, 512
    rays = []
    n = 16
    for i in range(n):
        a = 360 * i / n
        rays.append(f'<rect x="{cx - 34}" y="{cy - 330}" width="68" height="190" rx="34" '
                    f'fill="url(#ray)" transform="rotate({a:.2f} {cx} {cy})"/>')
    rays_s = "\n    ".join(rays)
    defs = """    <linearGradient id="bgC" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1f3a33"/>
      <stop offset="1" stop-color="#0c1a17"/>
    </linearGradient>
    <linearGradient id="ray" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#f6c15b"/><stop offset="1" stop-color="#c2562a"/>
    </linearGradient>
    <radialGradient id="hollow" cx=".5" cy=".35" r=".7">
      <stop offset="0" stop-color="#2a1712"/><stop offset="1" stop-color="#0d0707"/>
    </radialGradient>
    <radialGradient id="ember" cx=".5" cy=".5" r=".5">
      <stop offset="0" stop-color="#fff0c8"/><stop offset=".5" stop-color="#ffab45"/>
      <stop offset="1" stop-color="#ff7a2a" stop-opacity="0"/>
    </radialGradient>"""
    body = f"""    <rect width="{C}" height="{C}" fill="url(#bgC)"/>
    <circle cx="{cx}" cy="{cy}" r="300" fill="#f39b3f" opacity=".25" filter="url(#softer)"/>
    {rays_s}
    <circle cx="{cx}" cy="{cy}" r="178" fill="#e3873a"/>
    <circle cx="{cx}" cy="{cy}" r="150" fill="url(#hollow)"/>
    <ellipse cx="{cx}" cy="{cy + 78}" rx="96" ry="54" fill="url(#ember)"/>"""
    return frame(defs, body, "den — concept C: mane sun")


# ---------- Final: Concept A refined — mane ruff scallops, light pool, depth ----------
def final() -> str:
    cx, base = 512, 782
    # outer mane: arch w=580 top=222 -> arc centre y = 222 + 290
    R, acy = 290, 222 + 290
    lobes = []
    k = 19
    for i in range(k):
        t = math.radians(172 + 196 * i / (k - 1))      # sweep just past both shoulders
        mid = 1 - abs(i - (k - 1) / 2) / ((k - 1) / 2)  # 1 at top, 0 at sides
        r = 16 + 14 * mid
        x, y = cx + (R - r * 0.55) * math.cos(t), acy + (R - r * 0.55) * math.sin(t)
        lobes.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="url(#m3)"/>')
    lobes_s = "\n    ".join(lobes)
    defs = """    <linearGradient id="bgF" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#43263a"/>
      <stop offset=".75" stop-color="#1d1019"/>
    </linearGradient>
    <linearGradient id="m1" gradientUnits="userSpaceOnUse" x1="0" y1="350" x2="0" y2="782">
      <stop offset="0" stop-color="#f7c26c"/><stop offset="1" stop-color="#c7682f"/>
    </linearGradient>
    <linearGradient id="m2" gradientUnits="userSpaceOnUse" x1="0" y1="290" x2="0" y2="782">
      <stop offset="0" stop-color="#e2893f"/><stop offset="1" stop-color="#94401f"/>
    </linearGradient>
    <linearGradient id="m3" gradientUnits="userSpaceOnUse" x1="0" y1="170" x2="0" y2="782">
      <stop offset="0" stop-color="#b4552b"/><stop offset="1" stop-color="#5c2419"/>
    </linearGradient>
    <radialGradient id="glowF" cx=".5" cy=".95" r=".95">
      <stop offset="0" stop-color="#fff7e0"/>
      <stop offset=".32" stop-color="#ffd07a"/>
      <stop offset=".75" stop-color="#f08a36"/>
      <stop offset="1" stop-color="#c85a22"/>
    </radialGradient>
    <linearGradient id="floor" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1a0d13"/><stop offset="1" stop-color="#0d0609"/>
    </linearGradient>
    <radialGradient id="pool" cx=".5" cy="0" r=".5">
      <stop offset="0" stop-color="#ffc46b" stop-opacity=".55"/>
      <stop offset="1" stop-color="#ffc46b" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity=".22"/>
      <stop offset=".5" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>"""
    body = f"""    <rect width="{C}" height="{C}" fill="url(#bgF)"/>
    <ellipse cx="{cx}" cy="{base - 40}" rx="360" ry="200" fill="#ff8f3a" opacity=".22" filter="url(#softer)"/>
    {lobes_s}
    <path d="{arch(cx, base, 580, 222)}" fill="url(#m3)"/>
    <path d="{arch(cx, base, 470, 284)}" fill="#3a1812" opacity=".45" transform="translate(0 6)" filter="url(#soft)"/>
    <path d="{arch(cx, base, 470, 284)}" fill="url(#m2)"/>
    <path d="{arch(cx, base, 364, 346)}" fill="#3a1812" opacity=".45" transform="translate(0 6)" filter="url(#soft)"/>
    <path d="{arch(cx, base, 364, 346)}" fill="url(#m1)"/>
    <path d="{arch(cx, base, 364, 346)}" fill="url(#sheen)"/>
    <path d="{arch(cx, base, 254, 414)}" fill="#1c0e13"/>
    <path d="{arch(cx, base, 212, 440)}" fill="url(#glowF)"/>
    <clipPath id="floorclip"><rect x="0" y="{base}" width="{C}" height="{C - base}"/></clipPath>
    <rect x="0" y="{base}" width="{C}" height="{C - base}" fill="url(#floor)"/>
    <ellipse cx="{cx}" cy="{base}" rx="320" ry="120" fill="url(#pool)" clip-path="url(#floorclip)"/>
    <rect x="{cx - 260}" y="{base}" width="520" height="3" fill="#ffd79a" opacity=".45"/>"""
    return frame(defs, body, "den")


def full_bleed(svg: str) -> str:
    """macOS 26 masks full-bleed square icns art into its own squircle; a pre-shaped
    squircle gets shrunk onto a gray legacy plate. So the shipped icns uses the body
    region (100..924) scaled to the whole canvas, unclipped, with no shadow or rim."""
    lines = [l for l in svg.splitlines()
             if 'fill="#000" opacity=".28"' not in l and 'stroke="url(#rim)"' not in l]
    out = "\n".join(lines) + "\n"
    return (out.replace('<g clip-path="url(#sq)">', "<g>")
               .replace(f'viewBox="0 0 {C} {C}"', f'viewBox="{OFF} {OFF} {BODY} {BODY}"'))


if __name__ == "__main__":
    (OUT / "den-icon.svg").write_text(final())
    (OUT / "den-icon-fullbleed.svg").write_text(full_bleed(final()))
    print("wrote", OUT / "den-icon.svg", OUT / "den-icon-fullbleed.svg")
    for name, fn in [("concept-a", concept_a), ("concept-b", concept_b), ("concept-c", concept_c)]:
        (OUT / f"{name}.svg").write_text(fn())
        print("wrote", OUT / f"{name}.svg")
