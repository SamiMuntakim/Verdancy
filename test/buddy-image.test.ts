import { PNG } from 'pngjs';
import { processSprite, defringeMagenta, TARGET_SIZE } from '../src/lib/buddy';

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

describe('processSprite (chroma-key → de-fringe → crop → fit-centered)', () => {
  test('crops to the subject and fits it centered, preserving colors', () => {
    // 16x16 magenta with a 4-wide × 12-tall green bar centered → a tall subject.
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

    // Center pixel is opaque and keeps the exact source green (no palette snap).
    const ci = ((TARGET_SIZE / 2) * TARGET_SIZE + TARGET_SIZE / 2) * 4;
    expect(out.data[ci + 3]).toBe(255);
    expect([out.data[ci], out.data[ci + 1], out.data[ci + 2]]).toEqual([80, 150, 80]);
  });

  test('de-fringes residual magenta but spares genuine pink', () => {
    // pixel 0 = pink (red ≫ blue), pixel 1 = magenta fringe (red ≈ blue, low green).
    const data = Buffer.from([222, 120, 160, 255, 200, 40, 200, 255]);
    defringeMagenta({ width: 2, height: 1, data });
    expect(data[3]).toBe(255); // pink kept
    expect(data[7]).toBe(0); // magenta fringe removed
  });

  test('rejects an unsupported image format', () => {
    expect(() => processSprite(Buffer.from([1, 2, 3]), 'image/gif')).toThrow();
  });
});
