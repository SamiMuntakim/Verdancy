import { PNG } from 'pngjs';
import { decode as decodeJpeg } from 'jpeg-js';
import { ApiError } from './errors';

/**
 * Plant Buddy sprite post-processing (PRD Appendix A):
 *   flood-fill the flat background inward from the frame borders → clean the
 *   residual fringe at the alpha boundary → crop to the subject's bounding box →
 *   area-average downscale to fit TARGET_SIZE preserving aspect ratio → center on
 *   a transparent canvas → encode PNG. Pure functions over raw RGBA so the
 *   pipeline is deterministic and unit-testable without the model.
 *
 * Two deliberate choices fix the old "ugly bud":
 *   1. Background removal is CONNECTIVITY-based (flood fill from the borders), not
 *      a global color threshold. Only background-connected pixels are cleared, so
 *      an interior pink/magenta petal is never punched out. The prompt pads the
 *      character away from every edge, so the background is one continuous border.
 *   2. Downscaling averages source pixels (alpha-weighted box filter) instead of
 *      point-sampling. The model returns a large, smooth render; nearest-neighbor
 *      downscaling of that produces aliasing and speckle. Averaging is clean.
 *      Nearest-neighbor is kept only for the rare upscale (crisp, no blur).
 *
 * We do NOT snap to a fixed palette: the style-reference art is the house style.
 * Bump STYLE_VERSION when the art or pipeline changes so cached sprites re-generate.
 */

export const STYLE_VERSION = 4;
export const TARGET_SIZE = 256;

// Squared Euclidean tolerance for "is this pixel the background color". Generous
// enough to swallow JPEG-compression fringe around the flat field; connectivity
// from the borders keeps it from bleeding into the subject.
const BG_TOLERANCE_SQ = 110 * 110;

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

/** Average color of the four corner pixels — the reference background color. */
function sampleBackground(img: RawImage): [number, number, number] {
  const { width: w, height: h, data } = img;
  const corners = [0, (w - 1) * 4, (h - 1) * w * 4, ((h - 1) * w + (w - 1)) * 4];
  let r = 0;
  let g = 0;
  let b = 0;
  for (const i of corners) {
    r += data[i];
    g += data[i + 1];
    b += data[i + 2];
  }
  return [Math.round(r / 4), Math.round(g / 4), Math.round(b / 4)];
}

/**
 * Remove the flat background by flooding inward from the frame borders: seed every
 * border pixel that matches the sampled background color, then grow across
 * 4-connected neighbors within tolerance, clearing alpha as we go. Because the fill
 * only travels through background-connected pixels, interior subject colors — even
 * ones close to the background hue — are left fully intact.
 */
export function floodFillBackground(img: RawImage): RawImage {
  const { width: w, height: h, data } = img;
  const [br, bg, bb] = sampleBackground(img);
  const isBg = (i: number): boolean => {
    const dr = data[i] - br;
    const dg = data[i + 1] - bg;
    const db = data[i + 2] - bb;
    return dr * dr + dg * dg + db * db <= BG_TOLERANCE_SQ;
  };

  const visited = new Uint8Array(w * h);
  const stack: number[] = [];
  const seed = (x: number, y: number): void => {
    const p = y * w + x;
    if (!visited[p] && isBg(p * 4)) {
      visited[p] = 1;
      stack.push(p);
    }
  };
  for (let x = 0; x < w; x += 1) {
    seed(x, 0);
    seed(x, h - 1);
  }
  for (let y = 0; y < h; y += 1) {
    seed(0, y);
    seed(w - 1, y);
  }

  while (stack.length) {
    const p = stack.pop() as number;
    data[p * 4 + 3] = 0; // transparent
    const x = p % w;
    const y = (p - x) / w;
    if (x > 0) seed(x - 1, y);
    if (x < w - 1) seed(x + 1, y);
    if (y > 0) seed(x, y - 1);
    if (y < h - 1) seed(x, y + 1);
  }
  return img;
}

/**
 * Clean the anti-aliased seam left at the alpha boundary: opaque pixels that touch
 * transparency AND read as background-dominant (magenta: high red+blue, low green,
 * red ≈ blue). Restricted to the boundary, so interior pinks are never touched.
 */
export function defringeBoundary(img: RawImage): RawImage {
  const { width: w, height: h, data } = img;
  // Snapshot the original alpha so a just-cleared pixel can't make its neighbor
  // look like a new boundary and cascade the removal inward.
  const alpha0 = new Uint8Array(w * h);
  for (let p = 0; p < w * h; p += 1) alpha0[p] = data[p * 4 + 3];
  const transparentNeighbor = (x: number, y: number): boolean =>
    (x > 0 && alpha0[y * w + x - 1] === 0) ||
    (x < w - 1 && alpha0[y * w + x + 1] === 0) ||
    (y > 0 && alpha0[(y - 1) * w + x] === 0) ||
    (y < h - 1 && alpha0[(y + 1) * w + x] === 0);

  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      const i = (y * w + x) * 4;
      if (data[i + 3] === 0) continue;
      const r = data[i];
      const g = data[i + 1];
      const b = data[i + 2];
      if (r - g > 60 && b - g > 60 && Math.abs(r - b) < 60 && transparentNeighbor(x, y)) {
        data[i + 3] = 0;
      }
    }
  }
  return img;
}

/**
 * Keep only the largest 4-connected blob of opaque pixels; clear everything else.
 * The model (and overlaid "AI-generated" sparkle badges) can leave stray islands
 * floating in the background — those would otherwise inflate the crop box and shove
 * the real subject off-center. The bud is one connected component, so it survives.
 */
export function keepLargestComponent(img: RawImage): RawImage {
  const { width: w, height: h, data } = img;
  const n = w * h;
  const label = new Int32Array(n).fill(-1);
  let best = -1;
  let bestSize = 0;
  let current = 0;
  const queue = new Int32Array(n);
  for (let start = 0; start < n; start += 1) {
    if (label[start] !== -1 || data[start * 4 + 3] === 0) continue;
    let head = 0;
    let tail = 0;
    queue[tail++] = start;
    label[start] = current;
    let size = 0;
    while (head < tail) {
      const p = queue[head++];
      size += 1;
      const x = p % w;
      const y = (p - x) / w;
      const push = (q: number): void => {
        if (label[q] === -1 && data[q * 4 + 3] !== 0) {
          label[q] = current;
          queue[tail++] = q;
        }
      };
      if (x > 0) push(p - 1);
      if (x < w - 1) push(p + 1);
      if (y > 0) push(p - w);
      if (y < h - 1) push(p + w);
    }
    if (size > bestSize) {
      bestSize = size;
      best = current;
    }
    current += 1;
  }
  if (best === -1) return img; // nothing opaque
  for (let p = 0; p < n; p += 1) {
    if (label[p] !== best) data[p * 4 + 3] = 0;
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

/** Nearest-neighbor scale (hard pixel edges — used only when upscaling). */
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

/**
 * Area-average (box filter) downscale. Colors are averaged premultiplied by alpha
 * so transparent pixels don't bleed their (undefined) RGB into the subject edge —
 * that "black halo" is the classic RGBA-downscale bug. Alpha is averaged straight.
 */
export function scaleAreaAverage(src: RawImage, w2: number, h2: number): RawImage {
  const { width: sw, height: sh, data } = src;
  const out = Buffer.alloc(w2 * h2 * 4);
  for (let y = 0; y < h2; y += 1) {
    const sy0 = Math.floor((y * sh) / h2);
    const sy1 = Math.max(sy0 + 1, Math.floor(((y + 1) * sh) / h2));
    for (let x = 0; x < w2; x += 1) {
      const sx0 = Math.floor((x * sw) / w2);
      const sx1 = Math.max(sx0 + 1, Math.floor(((x + 1) * sw) / w2));
      let sr = 0;
      let sg = 0;
      let sb = 0;
      let sa = 0;
      let n = 0;
      for (let yy = sy0; yy < sy1; yy += 1) {
        for (let xx = sx0; xx < sx1; xx += 1) {
          const si = (yy * sw + xx) * 4;
          const a = data[si + 3];
          sr += data[si] * a;
          sg += data[si + 1] * a;
          sb += data[si + 2] * a;
          sa += a;
          n += 1;
        }
      }
      const di = (y * w2 + x) * 4;
      const alpha = Math.round(sa / n);
      if (sa > 0) {
        out[di] = Math.round(sr / sa);
        out[di + 1] = Math.round(sg / sa);
        out[di + 2] = Math.round(sb / sa);
      }
      out[di + 3] = alpha;
    }
  }
  return { width: w2, height: h2, data: out };
}

/**
 * Scale to fit `size`×`size` preserving aspect ratio, centered on transparent.
 * Downscale is area-averaged (clean); the rare upscale stays nearest (crisp).
 */
export function fitCentered(src: RawImage, size: number): RawImage {
  const scale = Math.min(size / src.width, size / src.height);
  const w2 = Math.max(1, Math.min(size, Math.round(src.width * scale)));
  const h2 = Math.max(1, Math.min(size, Math.round(src.height * scale)));
  const scaled = scale < 1 ? scaleAreaAverage(src, w2, h2) : scaleNearest(src, w2, h2);
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

/** Full pipeline: decode → flood-fill bg → defringe → keep-largest → crop → fit → PNG. */
export function processSprite(input: Buffer, mimeType: string): Buffer {
  const decoded = decodeImage(input, mimeType);
  floodFillBackground(decoded);
  defringeBoundary(decoded);
  keepLargestComponent(decoded);
  const cropped = cropToContent(decoded);
  const fitted = fitCentered(cropped, TARGET_SIZE);
  return encodePng(fitted);
}
