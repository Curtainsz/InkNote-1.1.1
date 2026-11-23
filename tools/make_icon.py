"""Draws the InkNote app icon (1024x1024, no transparency) with Pillow."""
from PIL import Image, ImageDraw, ImageFilter
import math, sys

S = 1024
K = 2  # supersampling
W = S * K
img = Image.new("RGB", (W, W))
px = img.load()

# Diagonal blue gradient background.
top, bottom = (74, 132, 238), (36, 62, 170)
for y in range(W):
    for x in range(0, W):
        t = (x + y) / (2 * (W - 1))
        px[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))

d = ImageDraw.Draw(img, "RGBA")

# Paper sheet with a soft shadow.
sx0, sy0, sx1, sy1 = 220 * K, 170 * K, 804 * K, 854 * K
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((sx0, sy0 + 18 * K, sx1, sy1 + 18 * K), 56 * K, fill=(0, 0, 40, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(26 * K))
img.paste(shadow, (0, 0), shadow)
d = ImageDraw.Draw(img, "RGBA")
d.rounded_rectangle((sx0, sy0, sx1, sy1), 56 * K, fill=(255, 255, 255, 255))

# Ruled lines and a margin.
for i in range(5):
    y = (330 + i * 100) * K
    d.line((sx0 + 50 * K, y, sx1 - 50 * K, y), fill=(196, 208, 236, 255), width=5 * K)
d.line((sx0 + 120 * K, sy0 + 36 * K, sx0 + 120 * K, sy1 - 36 * K), fill=(238, 120, 120, 150), width=4 * K)

# A handwritten wave of ink.
pts = []
for i in range(0, 901):
    t = i / 900
    x = (sx0 + 160 * K) + t * (sx1 - sx0 - 250 * K)
    y = 520 * K + math.sin(t * math.pi * 3.2) * 62 * K - t * 40 * K
    pts.append((x, y))
for p in pts:
    d.ellipse((p[0] - 11 * K, p[1] - 11 * K, p[0] + 11 * K, p[1] + 11 * K), fill=(30, 36, 70, 255))

# Pencil lying across the corner.
pencil = Image.new("RGBA", (W, W), (0, 0, 0, 0))
pd = ImageDraw.Draw(pencil)
L, H = 560 * K, 78 * K
cx, cy = 690 * K, 700 * K
body = [(-L / 2, -H / 2), (L / 2 - 90 * K, -H / 2), (L / 2 - 90 * K, H / 2), (-L / 2, H / 2)]
tip = [(L / 2 - 90 * K, -H / 2), (L / 2 + 40 * K, 0), (L / 2 - 90 * K, H / 2)]
lead = [(L / 2 + 8 * K, -H * 0.12), (L / 2 + 40 * K, 0), (L / 2 + 8 * K, H * 0.12)]
cap = [(-L / 2 - 40 * K, -H / 2), (-L / 2, -H / 2), (-L / 2, H / 2), (-L / 2 - 40 * K, H / 2)]
pd.polygon([(cx + x, cy + y) for x, y in body], fill=(255, 196, 61, 255))
pd.polygon([(cx + x, cy + y) for x, y in tip], fill=(250, 222, 176, 255))
pd.polygon([(cx + x, cy + y) for x, y in lead], fill=(40, 44, 70, 255))
pd.polygon([(cx + x, cy + y) for x, y in cap], fill=(238, 98, 110, 255))
pd.line([(cx - L / 2, cy), (cx + L / 2 - 90 * K, cy)], fill=(240, 160, 30, 255), width=4 * K)
pencil = pencil.rotate(38, center=(cx, cy), resample=Image.BICUBIC)
edge = pencil.filter(ImageFilter.GaussianBlur(10 * K))
shade = Image.new("RGBA", (W, W), (0, 0, 40, 0))
shade.putalpha(edge.split()[3].point(lambda a: int(a * 0.35)))
img.paste(shade, (6 * K, 12 * K), shade)
img.paste(pencil, (0, 0), pencil)

img = img.resize((S, S), Image.LANCZOS).convert("RGB")
out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
img.save(out, "PNG")
print("wrote", out, img.size, img.mode)
