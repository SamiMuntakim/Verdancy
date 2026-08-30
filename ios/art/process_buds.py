#!/usr/bin/env python3
"""Turn the raw 1024px chibi bud art (buds-source/) into the bundled sprite
imagesets under Assets.xcassets.

Each source PNG has an opaque pale background, a dark-outlined character, and a
soft ground shadow. Pipeline per image:
  1. corner flood-fill to knock out the (per-image) solid background — this keeps
     the character's own light greens, which a global color-key would eat;
  2. crop to the remaining content + pad to a square with a small margin;
  3. downscale to TARGET px (LANCZOS).

Run:  python3 process_buds.py            # needs Pillow
Idempotent — safe to re-run after editing the source art.
"""
from PIL import Image
from collections import deque
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "buds-source")
CAT = os.path.join(HERE, "..", "Verdancy", "Resources", "Assets.xcassets")

TOL = 60        # background color match tolerance (Euclidean)
TARGET = 256    # output sprite size, px
MARGIN = 0.06   # padding around content, as a fraction of the content side

# source filename -> asset (imageset) name
MAP = {
    "Broad-Leaf Tropicals.png": "bud-broadleaf",
    "Trailing and Vine.png": "bud-trailing",
    "Succulents and Cacti.png": "bud-succulent",
    "Upright and Architectural.png": "bud-upright",
    "Ferns and Delicate.png": "bud-fern",
    "Epiphytes and Orchids.png": "bud-orchid",
    "Pot.png": "bud-pot",  # pre-bloom / non-subscriber teaser
}

CONTENTS = (
    '{\n  "images" : [\n    {\n      "filename" : "%s.png",\n'
    '      "idiom" : "universal"\n    }\n  ],\n'
    '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
)


def knockout_bg(im):
    w, h = im.size
    px = im.load()
    corners = [im.getpixel(p)[:3] for p in [(0, 0), (w-1, 0), (0, h-1), (w-1, h-1)]]
    br = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
    tol2 = TOL * TOL

    def isbg(p):
        return (p[0]-br[0])**2 + (p[1]-br[1])**2 + (p[2]-br[2])**2 <= tol2

    seen = bytearray(w * h)
    dq = deque()
    for x in range(w):
        for y in (0, h-1):
            if not seen[y*w+x] and isbg(px[x, y][:3]):
                seen[y*w+x] = 1; dq.append((x, y))
    for y in range(h):
        for x in (0, w-1):
            if not seen[y*w+x] and isbg(px[x, y][:3]):
                seen[y*w+x] = 1; dq.append((x, y))
    while dq:
        x, y = dq.popleft()
        for nx, ny in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny*w+nx] and isbg(px[nx, ny][:3]):
                seen[ny*w+nx] = 1; dq.append((nx, ny))
    for y in range(h):
        for x in range(w):
            if seen[y*w+x]:
                r, g, b, _ = px[x, y]
                px[x, y] = (r, g, b, 0)


def process(src, name):
    im = Image.open(src).convert("RGBA")
    knockout_bg(im)
    im = im.crop(im.getbbox())
    cw, ch = im.size
    side = int(max(cw, ch) * (1 + 2 * MARGIN))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(im, ((side-cw)//2, (side-ch)//2), im)
    canvas = canvas.resize((TARGET, TARGET), Image.LANCZOS)
    out_dir = os.path.join(CAT, name + ".imageset")
    os.makedirs(out_dir, exist_ok=True)
    canvas.save(os.path.join(out_dir, name + ".png"))
    with open(os.path.join(out_dir, "Contents.json"), "w") as f:
        f.write(CONTENTS % name)
    print("wrote", name)


if __name__ == "__main__":
    for src_name, asset in MAP.items():
        process(os.path.join(SRC, src_name), asset)
