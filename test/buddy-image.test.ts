import { PNG } from 'pngjs';
import {
  processSprite,
  floodFillBackground,
  defringeBoundary,
  keepLargestComponent,
  cropToContent,
  scaleAreaAverage,
  TARGET_SIZE,
  type RawImage,
} from '../src/lib/buddy';

function makePng(
  w: number,
  h: number,
  fn: (x: number, y: number) => [number, number, number],
): Buffer {
  const png = new PNG({ width: w, height: h });
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      const i = (y * w + x) * 4;
      const [r, g, b] = fn(x, y);
      png.data[i] = r;
      png.data[i + 1] = g;
      png.data[i + 2] = b;
      png.data[i + 3] = 255;
    }
  }
  return PNG.sync.write(png);
}

function raw(
  w: number,
  h: number,
  fn: (x: number, y: number) => [number, number, number],
): RawImage {
  const data = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      const i = (y * w + x) * 4;
      const [r, g, b] = fn(x, y);
      data[i] = r;
      data[i + 1] = g;
      data[i + 2] = b;
      data[i + 3] = 255;
    }
  }
  return { width: w, height: h, data };
}

describe('processSprite (flood-fill bg → defringe boundary → crop → fit)', () => {
  test('crops to the subject and fits it centered, preserving colors', () => {
    // 16x16 magenta with a 4-wide × 12-tall green bar (padded from every edge).
    const src = makePng(16, 16, (x, y) =>
      x >= 6 && x <= 9 && y >= 2 && y <= 13 ? [80, 150, 80] : [255, 0, 255],
    );
    const out = PNG.sync.read(processSprite(src, 'image/png'));

    expect(out.width).toBe(TARGET_SIZE);
    expect(out.height).toBe(TARGET_SIZE);

    // A tall subject can't fill a square frame → corners stay transparent.
    expect(out.data[3]).toBe(0); // top-left
    const bottomRight = (TARGET_SIZE * TARGET_SIZE - 1) * 4;
    expect(out.data[bottomRight + 3]).toBe(0);

    // Center pixel is opaque and stays green (no palette snap).
    const ci = ((TARGET_SIZE / 2) * TARGET_SIZE + TARGET_SIZE / 2) * 4;
    expect(out.data[ci + 3]).toBe(255);
    expect(out.data[ci + 1]).toBeGreaterThan(out.data[ci]); // green-dominant
  });

  test('rejects an unsupported image format', () => {
    expect(() => processSprite(Buffer.from([1, 2, 3]), 'image/gif')).toThrow();
  });
});

describe('floodFillBackground (connectivity, not global threshold)', () => {
  test('spares an interior magenta petal that matches the background color', () => {
    // Green body filling the frame center, with a single magenta pixel buried
    // inside it. Background magenta borders the frame; the petal does not touch it.
    const img = raw(9, 9, (x, y) => {
      const inside = x >= 2 && x <= 6 && y >= 2 && y <= 6;
      if (!inside) return [255, 0, 255]; // background border
      if (x === 4 && y === 4) return [255, 0, 255]; // interior "petal", same hue
      return [80, 150, 80];
    });
    floodFillBackground(img);

    const at = (x: number, y: number) => img.data[(y * 9 + x) * 4 + 3];
    expect(at(0, 0)).toBe(0); // border cleared
    expect(at(4, 4)).toBe(255); // interior petal SPARED despite matching bg
    expect(at(2, 2)).toBe(255); // body opaque
  });

  test('clears the whole background even when the subject is offset', () => {
    const img = raw(10, 10, (x, y) =>
      x >= 5 && x <= 8 && y >= 5 && y <= 8 ? [80, 150, 80] : [255, 0, 255],
    );
    floodFillBackground(img);
    expect(img.data[3]).toBe(0); // far corner cleared
    expect(img.data[(6 * 10 + 6) * 4 + 3]).toBe(255); // subject kept
  });
});

describe('defringeBoundary', () => {
  test('clears magenta fringe touching transparency but spares interior magenta', () => {
    // Row: [transparent, magenta-fringe (touches transparent), interior magenta].
    const data = Buffer.from([
      0,
      0,
      0,
      0, // transparent
      200,
      40,
      200,
      255, // fringe, neighbors the transparent pixel
      200,
      40,
      200,
      255, // interior magenta, no transparent neighbor
    ]);
    defringeBoundary({ width: 3, height: 1, data });
    expect(data[7]).toBe(0); // fringe removed
    expect(data[11]).toBe(255); // interior magenta spared
  });
});

describe('scaleAreaAverage', () => {
  test('averages a 2x2 block instead of point-sampling', () => {
    // 2x2 with values 0,100,100,200 → mean 100 in a 1x1 downscale.
    const src: RawImage = {
      width: 2,
      height: 2,
      data: Buffer.from([0, 0, 0, 255, 100, 100, 100, 255, 100, 100, 100, 255, 200, 200, 200, 255]),
    };
    const out = scaleAreaAverage(src, 1, 1);
    expect(out.data[0]).toBe(100);
    expect(out.data[3]).toBe(255);
  });

  test('does not bleed transparent pixels into the subject color', () => {
    // One opaque red pixel + three fully-transparent pixels. The averaged color
    // must stay red (not darkened toward the transparent pixels' RGB).
    const src: RawImage = {
      width: 2,
      height: 2,
      data: Buffer.from([255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    };
    const out = scaleAreaAverage(src, 1, 1);
    expect(out.data[0]).toBe(255); // red preserved
    expect(out.data[3]).toBe(64); // alpha = 255/4 averaged
  });
});

describe('keepLargestComponent (drops stray islands like the ✦ badge)', () => {
  test('keeps the subject blob and clears a disconnected corner speck', () => {
    // Big 3x3 blob top-left, plus a lone 1px "sparkle" in the bottom-right corner.
    const img = raw(8, 8, (x, y) => {
      const blob = x >= 1 && x <= 3 && y >= 1 && y <= 3;
      const sparkle = x === 7 && y === 7;
      return blob || sparkle ? [80, 150, 80] : [0, 0, 0];
    });
    // Mark the black background transparent so only the two blobs are opaque.
    for (let p = 0; p < 64; p += 1) {
      const i = p * 4;
      if (img.data[i] === 0) img.data[i + 3] = 0;
    }
    keepLargestComponent(img);
    expect(img.data[(2 * 8 + 2) * 4 + 3]).toBe(255); // subject kept
    expect(img.data[(7 * 8 + 7) * 4 + 3]).toBe(0); // sparkle dropped
  });
});

describe('cropToContent', () => {
  test('returns the input when fully transparent', () => {
    const img = raw(4, 4, () => [0, 0, 0]);
    for (let i = 3; i < img.data.length; i += 4) img.data[i] = 0;
    expect(cropToContent(img)).toBe(img);
  });
});
