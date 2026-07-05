// Generates the iOS app icon and the bundled Plant Bud pixel-art sprites into the
// asset catalog. Deterministic programmer-art placeholders in the locked palette
// (src/lib/buddy.ts) — replace with hand-drawn art anytime by re-running your own
// files over the same names.
//
//   node scripts/generate-assets.mjs
//
// Outputs (ios/Verdancy/Resources/Assets.xcassets/):
//   AppIcon.appiconset/icon-1024.png (+ Contents.json)
//   bud-dormant / bud-bloom-generic / bud-bloom-broadleaf / bud-bloom-snake /
//   bud-bloom-trailing / bud-bloom-succulent  (.imageset each)

import { PNG } from 'pngjs';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const ASSETS = join(root, 'ios', 'Verdancy', 'Resources', 'Assets.xcassets');

// Locked palette (mirrors src/lib/buddy.ts PALETTE).
const C = {
  outline: [38, 43, 38],
  shadow: [60, 70, 60],
  deep: [44, 92, 51],
  leaf: [76, 145, 80],
  light: [124, 188, 110],
  pale: [183, 222, 148],
  highlight: [233, 245, 200],
  stem: [110, 78, 48],
  soil: [74, 53, 36],
  pot: [183, 102, 71],
  potLight: [214, 140, 102],
  pink: [222, 120, 160],
  yellow: [240, 200, 96],
};

class Canvas {
  constructor(size) {
    this.size = size;
    this.png = new PNG({ width: size, height: size });
  }
  px(x, y, [r, g, b], a = 255) {
    x = Math.round(x);
    y = Math.round(y);
    if (x < 0 || y < 0 || x >= this.size || y >= this.size) return;
    const i = (y * this.size + x) * 4;
    this.png.data[i] = r;
    this.png.data[i + 1] = g;
    this.png.data[i + 2] = b;
    this.png.data[i + 3] = a;
  }
  opaque(x, y) {
    if (x < 0 || y < 0 || x >= this.size || y >= this.size) return false;
    return this.png.data[(y * this.size + x) * 4 + 3] > 0;
  }
  rect(x0, y0, x1, y1, c) {
    for (let y = y0; y <= y1; y += 1) for (let x = x0; x <= x1; x += 1) this.px(x, y, c);
  }
  /** Axis-aligned ellipse with a top-left highlight band. */
  ellipse(cx, cy, rx, ry, c, cLight = null) {
    for (let y = Math.floor(cy - ry); y <= cy + ry; y += 1) {
      for (let x = Math.floor(cx - rx); x <= cx + rx; x += 1) {
        const nx = (x - cx) / rx;
        const ny = (y - cy) / ry;
        if (nx * nx + ny * ny <= 1) {
          const lit = cLight && nx + ny < -0.55;
          this.px(x, y, lit ? cLight : c);
        }
      }
    }
  }
  /** Thick line (for stems/vines). */
  line(x0, y0, x1, y1, w, c) {
    const steps = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0)) * 2 + 1;
    for (let i = 0; i <= steps; i += 1) {
      const t = i / steps;
      const x = x0 + (x1 - x0) * t;
      const y = y0 + (y1 - y0) * t;
      for (let dy = 0; dy < w; dy += 1)
        for (let dx = 0; dx < w; dx += 1) this.px(x + dx - w / 2, y + dy - w / 2, c);
    }
  }
  /** 1px sticker outline around everything opaque. */
  outline(c) {
    const mark = [];
    for (let y = 0; y < this.size; y += 1) {
      for (let x = 0; x < this.size; x += 1) {
        if (this.opaque(x, y)) continue;
        if (
          this.opaque(x + 1, y) ||
          this.opaque(x - 1, y) ||
          this.opaque(x, y + 1) ||
          this.opaque(x, y - 1)
        ) {
          mark.push([x, y]);
        }
      }
    }
    for (const [x, y] of mark) this.px(x, y, c);
  }
  save(path) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, PNG.sync.write(this.png));
  }
}

// ---------------------------------------------------------------------------
// Sprite parts (64x64)
// ---------------------------------------------------------------------------
function drawPot(cv, { sleeping = false } = {}) {
  // Rim + tapered pot body.
  cv.rect(17, 42, 47, 45, C.potLight);
  for (let y = 46; y <= 58; y += 1) {
    const inset = Math.round(((y - 46) / 12) * 4);
    cv.rect(19 + inset, y, 45 - inset, y, C.pot);
    cv.px(20 + inset, y, C.potLight); // left highlight
  }
  cv.rect(20, 42, 44, 43, C.soil); // soil peeking over the rim
  // Face — chibi eyes + smile on the pot.
  if (sleeping) {
    cv.rect(25, 50, 28, 50, C.outline);
    cv.rect(36, 50, 39, 50, C.outline);
  } else {
    cv.rect(26, 49, 27, 51, C.outline);
    cv.rect(37, 49, 38, 51, C.outline);
  }
  cv.px(30, 53, C.outline);
  cv.rect(31, 54, 33, 54, C.outline);
  cv.px(34, 53, C.outline);
}

function blade(cv, xc, topY, maxW, lean, c, cEdge) {
  for (let y = topY; y <= 43; y += 1) {
    const t = (y - topY) / (43 - topY);
    const w = Math.max(1, Math.round(maxW * (0.25 + 0.75 * t)));
    const x = Math.round(xc + lean * (1 - t));
    cv.rect(x - Math.floor(w / 2), y, x + Math.ceil(w / 2) - 1, y, c);
    if (w >= 3 && cEdge) cv.px(x - Math.floor(w / 2), y, cEdge);
  }
}

const sprites = {
  'bud-dormant': (cv) => {
    drawPot(cv, { sleeping: true });
    cv.line(32, 42, 32, 32, 2, C.stem);
    cv.ellipse(32, 25, 6, 9, C.deep, C.shadow);
    cv.ellipse(32, 20, 2, 3, C.leaf); // tip hinting at what's coming
  },
  'bud-bloom-generic': (cv) => {
    drawPot(cv);
    cv.line(32, 42, 32, 24, 2, C.stem);
    cv.ellipse(24, 32, 6, 4, C.leaf, C.light);
    cv.ellipse(40, 32, 6, 4, C.leaf, C.light);
    cv.ellipse(32, 17, 6, 6, C.pink);
    cv.ellipse(32, 17, 2, 2, C.yellow);
  },
  'bud-bloom-broadleaf': (cv) => {
    drawPot(cv);
    cv.line(24, 42, 22, 28, 2, C.stem);
    cv.line(32, 42, 32, 20, 2, C.stem);
    cv.line(40, 42, 42, 28, 2, C.stem);
    cv.ellipse(21, 23, 6, 8, C.leaf, C.light);
    cv.ellipse(43, 23, 6, 8, C.leaf, C.light);
    cv.ellipse(32, 14, 7, 9, C.deep, C.leaf);
    cv.px(32, 10, C.pale);
  },
  'bud-bloom-snake': (cv) => {
    drawPot(cv);
    blade(cv, 24, 20, 4, -2, C.leaf, C.pale);
    blade(cv, 29, 14, 4, -1, C.deep, C.pale);
    blade(cv, 34, 11, 5, 0, C.leaf, C.pale);
    blade(cv, 39, 16, 4, 1, C.deep, C.pale);
    blade(cv, 43, 24, 3, 2, C.leaf, C.pale);
  },
  'bud-bloom-trailing': (cv) => {
    drawPot(cv);
    cv.ellipse(32, 34, 9, 6, C.leaf, C.light);
    cv.ellipse(26, 30, 4, 3, C.deep);
    cv.ellipse(39, 31, 4, 3, C.deep);
    // Two vines spilling over the rim.
    for (const [sx, dir] of [
      [20, -1],
      [44, 1],
    ]) {
      cv.line(sx, 40, sx + dir * 3, 50, 1, C.deep);
      cv.ellipse(sx + dir * 1, 44, 2, 2, C.leaf);
      cv.ellipse(sx + dir * 3, 50, 2, 2, C.light);
      cv.ellipse(sx + dir * 4, 55, 2, 2, C.leaf);
    }
  },
  'bud-bloom-succulent': (cv) => {
    drawPot(cv);
    blade(cv, 32, 16, 5, 0, C.leaf, C.pale);
    blade(cv, 26, 22, 4, -4, C.deep, C.pale);
    blade(cv, 38, 22, 4, 4, C.deep, C.pale);
    blade(cv, 22, 30, 3, -7, C.leaf, C.pale);
    blade(cv, 42, 30, 3, 7, C.leaf, C.pale);
  },
};

// ---------------------------------------------------------------------------
// App icon (1024): pale leaf (vesica) at 45° on deep green.
// ---------------------------------------------------------------------------
function drawIcon() {
  const size = 1024;
  const cv = new Canvas(size);
  for (let y = 0; y < size; y += 1) for (let x = 0; x < size; x += 1) cv.px(x, y, [44, 92, 51]);

  const R = 436;
  const d = 296; // lens: length ~640, width ~280
  const cos = Math.SQRT1_2;
  const cx = 512;
  const cy = 512;
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      // rotate -45° into leaf space
      const rx = (x - cx) * cos + (y - cy) * cos;
      const ry = -(x - cx) * cos + (y - cy) * cos;
      const inLens = Math.hypot(rx, ry - d) <= R && Math.hypot(rx, ry + d) <= R;
      if (!inLens) continue;
      cv.px(x, y, Math.abs(ry) < 8 ? [76, 145, 80] : [183, 222, 148]);
    }
  }
  // Stem continuing from the lower-right tip (tip ≈ rx=+320, ry=0; inverse
  // rotation maps (rx,0) → (cx + rx/√2, cy + rx/√2)).
  for (let t = 0; t < 150; t += 1) {
    const rx = 300 + t;
    const x = cx + rx * cos;
    const y = cy + rx * cos;
    for (let dy = -9; dy <= 9; dy += 1)
      for (let dx = -9; dx <= 9; dx += 1) cv.px(x + dx, y + dy, [76, 145, 80]);
  }
  return cv;
}

// ---------------------------------------------------------------------------
// Write everything
// ---------------------------------------------------------------------------
const budContents = (file) =>
  JSON.stringify(
    { images: [{ filename: file, idiom: 'universal' }], info: { author: 'xcode', version: 1 } },
    null,
    2,
  ) + '\n';

for (const [name, draw] of Object.entries(sprites)) {
  const cv = new Canvas(64);
  draw(cv);
  cv.outline(C.outline);
  const dir = join(ASSETS, `${name}.imageset`);
  cv.save(join(dir, `${name}.png`));
  writeFileSync(join(dir, 'Contents.json'), budContents(`${name}.png`));
  console.log(`sprite  ${name}`);
}

const icon = drawIcon();
const iconDir = join(ASSETS, 'AppIcon.appiconset');
icon.save(join(iconDir, 'icon-1024.png'));
writeFileSync(
  join(iconDir, 'Contents.json'),
  JSON.stringify(
    {
      images: [
        { filename: 'icon-1024.png', idiom: 'universal', platform: 'ios', size: '1024x1024' },
      ],
      info: { author: 'xcode', version: 1 },
    },
    null,
    2,
  ) + '\n',
);
console.log('icon    AppIcon 1024x1024');
console.log('Done.');
