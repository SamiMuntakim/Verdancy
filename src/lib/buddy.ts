import { PNG } from 'pngjs';
import { decode as decodeJpeg } from 'jpeg-js';
import { ApiError } from './errors';

/**
 * Plant Buddy sprite post-processing (PRD Appendix A):
 *   chroma-key the flat magenta background → de-fringe residual magenta → crop to
 *   the subject's bounding box → scale to fit 64px preserving aspect ratio →
 *   center on a transparent canvas → encode PNG. Pure functions over raw RGBA so
 *   the pipeline is deterministic and unit-testable without the model.
 *
 * Cropping + aspect-preserving fit makes the bud fill the sprite consistently
 * however the model framed it — a small / off-center / odd-aspect subject no
 * longer stretches into a sliver. We deliberately do NOT snap to a fixed palette:
 * the style-reference art is the house style. Bump STYLE_VERSION when the art or
 * pipeline changes so cached sprites re-generate.
 */

export const STYLE_VERSION = 3;
export const TARGET_SIZE = 64;

const CHROMA = { r: 255, g: 0, b: 255 };
const CHROMA_DISTANCE_SQ = 100 * 100; // squared Euclidean tolerance around magenta

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

/**
 * Drop residual magenta fringe (anti-aliased background edges the chroma-key
 * missed): opaque pixels that are magenta-dominant — high red AND blue, low
 * green, with red ≈ blue. Genuine pinks (red ≫ blue) are spared.
 */
export function defringeMagenta(img: RawImage): RawImage {
  const { data } = img;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] === 0) continue;
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    if (r - g > 60 && b - g > 60 && Math.abs(r - b) < 60) data[i + 3] = 0;
  }
  return img;
}

/** Crop to the bounding box of opaque pixels (returns the input if nothing's opaque). */
export function cropToContent(img: RawImage): RawImage {
  const { width: w, height: h, data } = img;
  let minX = w;
  let minY = h;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      if (data[(y * w + x) * 4 + 3] !== 0) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < minX) return img; // fully transparent — nothing to crop
  const cw = maxX - minX + 1;
  const ch = maxY - minY + 1;
  const out = Buffer.alloc(cw * ch * 4);
  for (let y = 0; y < ch; y += 1) {
    for (let x = 0; x < cw; x += 1) {
      const si = ((minY + y) * w + (minX + x)) * 4;
      const di = (y * cw + x) * 4;
      out[di] = data[si];
      out[di + 1] = data[si + 1];
      out[di + 2] = data[si + 2];
      out[di + 3] = data[si + 3];
    }
  }
  return { width: cw, height: ch, data: out };
}

/** Nearest-neighbor scale to arbitrary dimensions (hard pixel edges — no blending). */
export function scaleNearest(src: RawImage, w2: number, h2: number): RawImage {
  const out = Buffer.alloc(w2 * h2 * 4);
  for (let y = 0; y < h2; y += 1) {
    const sy = Math.min(src.height - 1, Math.floor((y * src.height) / h2));
    for (let x = 0; x < w2; x += 1) {
      const sx = Math.min(src.width - 1, Math.floor((x * src.width) / w2));
      const si = (sy * src.width + sx) * 4;
      const di = (y * w2 + x) * 4;
      out[di] = src.data[si];
      out[di + 1] = src.data[si + 1];
      out[di + 2] = src.data[si + 2];
      out[di + 3] = src.data[si + 3];
    }
  }
  return { width: w2, height: h2, data: out };
}

/** Scale to fit `size`×`size` preserving aspect ratio, centered on transparent. */
export function fitCentered(src: RawImage, size: number): RawImage {
  const scale = Math.min(size / src.width, size / src.height);
  const w2 = Math.max(1, Math.min(size, Math.round(src.width * scale)));
  const h2 = Math.max(1, Math.min(size, Math.round(src.height * scale)));
  const scaled = scaleNearest(src, w2, h2);
  const out = Buffer.alloc(size * size * 4); // zeroed = fully transparent
  const ox = Math.floor((size - w2) / 2);
  const oy = Math.floor((size - h2) / 2);
  for (let y = 0; y < h2; y += 1) {
    for (let x = 0; x < w2; x += 1) {
      const si = (y * w2 + x) * 4;
      const di = ((oy + y) * size + (ox + x)) * 4;
      out[di] = scaled.data[si];
      out[di + 1] = scaled.data[si + 1];
      out[di + 2] = scaled.data[si + 2];
      out[di + 3] = scaled.data[si + 3];
    }
  }
  return { width: size, height: size, data: out };
}

export function encodePng(img: RawImage): Buffer {
  const png = new PNG({ width: img.width, height: img.height });
  img.data.copy(png.data);
  return PNG.sync.write(png);
}

/** Full pipeline: decode → chroma-key → de-fringe → crop → fit-centered → PNG. */
export function processSprite(input: Buffer, mimeType: string): Buffer {
  const decoded = decodeImage(input, mimeType);
  const keyed = chromaKey(decoded);
  defringeMagenta(keyed);
  const cropped = cropToContent(keyed);
  const fitted = fitCentered(cropped, TARGET_SIZE);
  return encodePng(fitted);
}
