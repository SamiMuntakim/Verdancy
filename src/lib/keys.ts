import { randomUUID } from 'node:crypto';
import { ApiError } from './errors';

/**
 * DynamoDB + S3 key construction and object-level ownership checks.
 *
 * Hard invariants: identity comes only from the JWT `sub`; the SERVER generates
 * every S3 key under `u/<sub>/…`; and any client-supplied `image_ref` must be
 * confirmed to live under the caller's prefix before use (→ 403 otherwise).
 */

export const userPk = (sub: string): string => `USER#${sub}`;
export const META_SK = 'METADATA';
export const plantSk = (plantId: string): string => `PLANT#${plantId}`;
export const photoSkPrefix = (plantId: string): string => `PHOTO#${plantId}#`;
export const photoSk = (plantId: string, ts: string): string => `PHOTO#${plantId}#${ts}`;
export const quotaSk = (day: string): string => `QUOTA#${day}`;

// Plant Buddy (post-MVP): one shared sprite per normalized species.
export const speciesPk = (species: string): string => `SPECIES#${species}`;
export const BUDDY_SK = 'BUDDY';

/** URL-safe slug for the species, used in the sprite S3 key. */
export function speciesSlug(species: string): string {
  return species.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

/** Sprite object key in the (CloudFront-fronted) sprite bucket. style_version in
 *  the path lets the art be fully re-cached without invalidations. */
export function spriteKey(species: string, styleVersion: number): string {
  return `sprites/${speciesSlug(species)}/v${styleVersion}.png`;
}

/** Server-minted S3 key: `u/<sub>/p/<plantId>/<uuid>.jpg`. */
export function newImageKey(sub: string, plantId: string): string {
  return `u/${sub}/p/${plantId}/${randomUUID()}.jpg`;
}

/** Throw 403 unless `imageRef` lives under the caller's `u/<sub>/` prefix. */
export function assertOwnsKey(sub: string, imageRef: unknown): asserts imageRef is string {
  if (typeof imageRef !== 'string' || !imageRef.startsWith(`u/${sub}/`)) {
    throw new ApiError(403, 'Forbidden');
  }
}

/** Extract the plantId embedded in a (caller-owned) image key. */
export function plantIdFromKey(imageRef: string): string {
  const match = /^u\/[^/]+\/p\/([^/]+)\/[^/]+$/.exec(imageRef);
  if (!match) throw new ApiError(400, 'Invalid image_ref');
  return match[1];
}
