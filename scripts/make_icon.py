"""Draws the app icon (the home screen's bento grid). Run: python3 scripts/make_icon.py"""
from PIL import Image, ImageDraw
import os

S = 4  # supersample
W = 1024 * S
paper, ink, card, green = (247, 245, 237), (17, 17, 17), (255, 255, 255), (33, 173, 84)
img = Image.new("RGB", (W, W), paper)
d = ImageDraw.Draw(img)

def tile(x0, y0, x1, y1, fill=card):
    x0, y0, x1, y1 = (v * S for v in (x0, y0, x1, y1))
    r, line, shadow = 56 * S, 20 * S, 22 * S
    d.rounded_rectangle((x0 + shadow, y0 + shadow, x1 + shadow, y1 + shadow), r, fill=ink)
    d.rounded_rectangle((x0, y0, x1, y1), r, fill=fill, outline=ink, width=line)

m, g = 150, 46            # margin, gap
top = (m, m, 1024 - m - 22, 412)
tile(*top)
left = (m, top[3] + g, 512 - g // 2 - 11, 1024 - m - 22)
tile(*left)
rx0 = left[2] + g
mid = (left[1] + left[3]) // 2
tile(rx0, left[1], top[2], mid - g // 2)
tile(rx0, mid + g // 2, top[2], left[3], fill=green)

# a little heatmap in the wide tile
cell, gap = 34, 12
cols, rows = 9, 3
x = top[2] - 48 - cols * cell - (cols - 1) * gap
y = (top[1] + top[3]) // 2 - (rows * cell + (rows - 1) * gap) // 2
on = {(8, 0), (8, 1), (7, 1), (6, 2), (8, 2), (5, 0), (3, 1), (7, 2)}
for c in range(cols):
    for r in range(rows):
        cx, cy = x + c * (cell + gap), y + r * (cell + gap)
        col = green if (c, r) in on else (232, 230, 224)
        d.rounded_rectangle(tuple(v * S for v in (cx, cy, cx + cell, cy + cell)), 8 * S, fill=col)
# a dumbbell-ish circle badge on the wide tile's left
bx, by, br = top[0] + 120, (top[1] + top[3]) // 2, 62
d.ellipse(tuple(v * S for v in (bx - br, by - br, bx + br, by + br)), outline=ink, width=16 * S)
d.rectangle(tuple(v * S for v in (bx - 40, by - 5, bx + 40, by + 5)), fill=ink)
for dx, h in ((-20, 30), (20, 30), (-34, 18), (34, 18)):
    d.rounded_rectangle(tuple(v * S for v in (bx + dx - 6, by - h, bx + dx + 6, by + h)), 5 * S, fill=ink)

out = os.path.join(os.path.dirname(__file__), "..", "Bento", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")
img.resize((1024, 1024), Image.LANCZOS).save(out)
print("wrote", os.path.normpath(out))
