import { PNG } from 'pngjs';
import { decode as decodeJpeg } from 'jpeg-js';
import { ApiError } from './errors';

/**
 * Plant Buddy sprite post-processing (PRD Appendix A):
 *   chroma-key to transparent → nearest-neighbor downscale → quantize to the
 *   locked palette. Pure functions over raw RGBA so the pipeline is deterministic
 *   and unit-testable without the model or any native image binary.
 *
 * The generation prompt asks for the bud on a flat magenta (#FF00FF) field; we
 * key that out, downscale with nearest-neighbor (hard pixel edges — no blending),
 * then snap every remaining pixel to the locked palette.
 */

export const STYLE_VERSION = 1;
export const TARGET_SIZE = 64;

const CHROMA = { r: 255, g: 0, b: 255 };
const CHROMA_DISTANCE_SQ = 90 * 90; // squared Euclidean tolerance around magenta

/** The locked palette — tune this to revamp the art (and bump STYLE_VERSION). */
export const PALETTE: ReadonlyArray<readonly [number, number, number]> = [
  [38, 43, 38], // near-black outline
  [60, 70, 60], // shadow green
  [44, 92, 51], // deep leaf
  [76, 145, 80], // leaf
  [124, 188, 110], // light leaf
  [183, 222, 148], // pale leaf
  [233, 245, 200], // leaf highlight
  [110, 78, 48], // stem brown
  [140, 100, 64], // mid brown
  [74, 53, 36], // soil
  [183, 102, 71], // terracotta pot
  [214, 140, 102], // pot light
  [222, 120, 160], // flower pink
  [240, 200, 96], // flower yellow
  [96, 150, 186], // water blue
  [245, 245, 240], // white
];

export interface RawImage {
  width: number;
  height: number;
  data: Buffer; // RGBA, length = width*height*4
}

export function decodeImage(input: Buffer, mimeType: string): RawImage {
  if (/png/i.test(mimeType)) {
    const png = PNG.sync.read(input);
    return { width: png.width, height: png.height, data: png.data };
  }
  if (/jpe?g/i.test(mimeType)) {
    const img = decodeJpeg(input, { formatAsRGBA: true });
    return { width: img.width, height: img.height, data: Buffer.from(img.data) };
  }
  throw new ApiError(502, 'Unsupported image format from the model');
}

export function chromaKey(img: RawImage): RawImage {
  const { data } = img;
  for (let i = 0; i < data.length; i += 4) {
    const dr = data[i] - CHROMA.r;
    const dg = data[i + 1] - CHROMA.g;
    const db = data[i + 2] - CHROMA.b;
    if (dr * dr + dg * dg + db * db <= CHROMA_DISTANCE_SQ) {
      data[i + 3] = 0; // transparent
    }
  }
  return img;
}

export function downscaleNearest(src: RawImage, size: number): RawImage {
  const out = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y += 1) {
    const sy = Math.floor((y * src.height) / size);
    for (let x = 0; x < size; x += 1) {
      const sx = Math.floor((x * src.width) / size);
      const si = (sy * src.width + sx) * 4;
      const di = (y * size + x) * 4;
      out[di] = src.data[si];
      out[di + 1] = src.data[si + 1];
      out[di + 2] = src.data[si + 2];
      out[di + 3] = src.data[si + 3];
    }
  }
  return { width: size, height: size, data: out };
}

function nearestPaletteColor(r: number, g: number, b: number): readonly [number, number, number] {
  let best = PALETTE[0];
  let bestDist = Infinity;
  for (const c of PALETTE) {
    const dr = r - c[0];
    const dg = g - c[1];
    const db = b - c[2];
    const dist = dr * dr + dg * dg + db * db;
    if (dist < bestDist) {
      bestDist = dist;
      best = c;
    }
  }
  return best;
}

export function quantizeToPalette(img: RawImage): RawImage {
  const { data } = img;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] === 0) continue; // leave transparent pixels alone
    const [r, g, b] = nearestPaletteColor(data[i], data[i + 1], data[i + 2]);
    data[i] = r;
    data[i + 1] = g;
    data[i + 2] = b;
  }
  return img;
}

export function encodePng(img: RawImage): Buffer {
  const png = new PNG({ width: img.width, height: img.height });
  img.data.copy(png.data);
  return PNG.sync.write(png);
}

/** Full pipeline: decode → chroma-key → downscale → quantize → encode PNG. */
export function processSprite(input: Buffer, mimeType: string): Buffer {
  const decoded = decodeImage(input, mimeType);
  const keyed = chromaKey(decoded);
  const small = downscaleNearest(keyed, TARGET_SIZE);
  const quantized = quantizeToPalette(small);
  return encodePng(quantized);
}
