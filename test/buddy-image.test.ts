import { PNG } from 'pngjs';
import { processSprite, PALETTE, TARGET_SIZE } from '../src/lib/buddy';

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

describe('processSprite (chroma-key → downscale → quantize)', () => {
  test('keys out magenta, emits a 64x64 palette-quantized PNG', () => {
    // 16x16: 2px magenta border, green interior.
    const src = makePng(16, 16, (x, y) =>
      x < 2 || y < 2 || x > 13 || y > 13 ? [255, 0, 255] : [80, 150, 80],
    );
    const out = PNG.sync.read(processSprite(src, 'image/png'));

    expect(out.width).toBe(TARGET_SIZE);
    expect(out.height).toBe(TARGET_SIZE);

    // Top-left corner came from the magenta border → transparent.
    expect(out.data[3]).toBe(0);

    // Center pixel is opaque and snapped to a locked-palette color.
    const ci = ((TARGET_SIZE / 2) * TARGET_SIZE + TARGET_SIZE / 2) * 4;
    expect(out.data[ci + 3]).toBe(255);
    const inPalette = PALETTE.some(
      (c) => c[0] === out.data[ci] && c[1] === out.data[ci + 1] && c[2] === out.data[ci + 2],
    );
    expect(inPalette).toBe(true);
  });

  test('rejects an unsupported image format', () => {
    expect(() => processSprite(Buffer.from([1, 2, 3]), 'image/gif')).toThrow();
  });
});
