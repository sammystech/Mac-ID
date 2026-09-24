#!/usr/bin/env python3
"""
Draws the installer DMG's background: the "drag Mac ID into Applications" window.

Rendered at 1x and 2x and combined into one TIFF, so it's crisp on Retina screens and correct on
others. Geometry must match dmg_settings.py: a 660x400 window with the app at (170, 200) and the
Applications link at (490, 200), 128 px icons.
"""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 660, 400
APP_X, APPS_X, ICON_Y, ICON = 170, 490, 200, 128
FONT = "/System/Library/Fonts/SFNS.ttf"

# Light on purpose. Finder draws icon labels in black over a background picture - even in dark
# mode - so on a dark background the "Applications" label all but disappears.
BG_TOP, BG_BOTTOM = (251, 250, 254), (238, 236, 247)
VIOLET = (109, 74, 255)
TEXT, TEXT_DIM, TEXT_FAINT = (24, 21, 43), (92, 88, 116), (138, 134, 160)


def font(size, scale, weight):
    f = ImageFont.truetype(FONT, int(size * scale))
    # SF Pro is a variable font with axes in this order: Width, Optical Size, GRAD, Weight. Passing
    # only a weight sets the *width* instead, and the text comes out stretched.
    try:
        f.set_variation_by_axes([100, max(17, min(96, size)), 400, weight])
    except Exception:
        pass
    return f


def draw(scale):
    w, h = int(W * scale), int(H * scale)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):                           # quiet vertical gradient
        t = y / (h - 1)
        c = tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c

    # One soft violet glow where the eye should travel, not decoration everywhere.
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse(
        [w * 0.30, ICON_Y * scale - 70 * scale, w * 0.70, ICON_Y * scale + 70 * scale], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(60 * scale))
    img = Image.composite(Image.new("RGB", (w, h), VIOLET), img, glow.point(lambda v: v * 0.18))

    d = ImageDraw.Draw(img)
    title = font(24, scale, 650)
    sub = font(13.5, scale, 450)
    note = font(12, scale, 450)
    d.text((w / 2, 46 * scale), "Drag Mac ID into Applications", font=title, fill=TEXT, anchor="mm")
    d.text((w / 2, 76 * scale), "Then open it from your Applications folder.", font=sub, fill=TEXT_DIM, anchor="mm")

    # Arrow between the icons: a gentle arc with a clean head.
    x0, x1 = (APP_X + ICON / 2 + 22) * scale, (APPS_X - ICON / 2 - 22) * scale
    y = ICON_Y * scale
    lift = 16 * scale
    pts = []
    for i in range(61):
        t = i / 60
        pts.append((x0 + (x1 - x0) * t, y - lift * math.sin(math.pi * t)))
    ang = math.atan2(pts[-1][1] - pts[-3][1], pts[-1][0] - pts[-3][0])
    head = 13 * scale
    tip = pts[-1]
    # Stop the line inside the arrowhead so it doesn't poke out past the tip.
    shaft = [p for p in pts if math.hypot(tip[0] - p[0], tip[1] - p[1]) > head * 0.7]
    d.line(shaft, fill=VIOLET, width=max(2, int(3 * scale)), joint="curve")
    left = (tip[0] - head * math.cos(ang - 0.5), tip[1] - head * math.sin(ang - 0.5))
    right = (tip[0] - head * math.cos(ang + 0.5), tip[1] - head * math.sin(ang + 0.5))
    d.polygon([tip, left, right], fill=VIOLET)

    d.text((w / 2, (H - 34) * scale), "Signed and notarized by Apple  ·  macid.net",
           font=note, fill=TEXT_FAINT, anchor="mm")
    return img


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    draw(1).save(f"{out}/background.png")
    draw(2).save(f"{out}/background@2x.png")
    print("drew background.png and background@2x.png")
