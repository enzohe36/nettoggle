"""Draw AppIcon.icns: a slashed network symbol, Claude-style white on clay, in the macOS app icon shape."""
import math, subprocess, tempfile, pathlib
from PIL import Image, ImageDraw, ImageFilter

CANVAS, BODY, RADIUS = 1024, 824, 185   # Apple's icon grid: 824 px body on a 1024 px canvas
SS = 4                                   # supersampling for smooth edges
BG, FG = (217, 119, 87), (255, 255, 255)   # Claude clay background, white symbol

def s(v): return int(v * SS)

body = Image.new("RGBA", (s(BODY), s(BODY)), BG + (255,))
d = ImageDraw.Draw(body)

def dot(x, y, r, color):
    d.ellipse((s(x - r), s(y - r), s(x + r), s(y + r)), fill=color)

def round_line(p0, p1, width, color):
    d.line((s(p0[0]), s(p0[1]), s(p1[0]), s(p1[1])), fill=color, width=s(width))
    for x, y in (p0, p1): dot(x, y, width / 2, color)

def arc(cx, cy, r, a0, a1, width, color):
    d.arc((s(cx - r), s(cy - r), s(cx + r), s(cy + r)), a0, a1, fill=color, width=s(width))
    for a in (a0, a1):   # round caps
        rm = r - width / 2
        dot(cx + rm * math.cos(math.radians(a)), cy + rm * math.sin(math.radians(a)), width / 2, color)

# Network symbol: a dot and three arcs fanning upwards, drawn at scale K and centred in the body
# (the symbol spans wy - 372K, top of the slash, to wy + 60K, bottom of the slash).
K = 1.2
wx, wy, stroke = BODY / 2, BODY / 2 + 156 * K, 56 * K
dot(wx, wy, 40 * K, FG + (255,))
for r in (140, 230, 320):
    arc(wx, wy, r * K, 225, 315, stroke, FG + (255,))

# Slash through it, cut out of the arcs by a border in the background colour.
p0, p1 = (wx - 168 * K, wy - 344 * K), (wx + 114 * K, wy + 32 * K)
round_line(p0, p1, stroke + 44 * K, BG + (255,))
round_line(p0, p1, stroke, FG + (255,))

body = body.resize((BODY, BODY), Image.LANCZOS)
mask = Image.new("L", (s(BODY), s(BODY)), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, s(BODY) - 1, s(BODY) - 1), s(RADIUS), fill=255)
mask = mask.resize((BODY, BODY), Image.LANCZOS)
body.putalpha(mask)

offset = (CANVAS - BODY) // 2
icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
shadow_alpha = Image.new("L", (CANVAS, CANVAS), 0)
shadow_alpha.paste(mask.point(lambda a: a * 0.3), (offset, offset + 10))
icon.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(12)))
icon.alpha_composite(body, (offset, offset))

here = pathlib.Path(__file__).parent
with tempfile.TemporaryDirectory() as tmp:
    iconset = pathlib.Path(tmp) / "AppIcon.iconset"; iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", here / "AppIcon.icns"], check=True)
icon.save(here / "AppIcon.png")
