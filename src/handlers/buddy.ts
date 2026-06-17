import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyResultV2 } from 'aws-lambda';
import { json, getSub, parseJsonBody } from '../lib/http';
import { ApiError, toErrorResponse } from '../lib/errors';
import { requireEnv } from '../lib/env';
import { normalizeSpecies } from '../lib/species';
import { spriteKey } from '../lib/keys';
import {
  listPlants,
  getBuddy,
  claimBuddyGeneration,
  finalizeBuddy,
  failBuddy,
  type BuddyRecord,
} from '../lib/dynamo';
import { generateBuddyImage } from '../lib/gemini';
import { processSprite, STYLE_VERSION } from '../lib/buddy';
import { putSprite } from '../lib/s3';

/**
 * Plant Buddy generation proxy (PRD Appendix A). POST /buddy {species}. Buds are
 * shared per normalized species and generated exactly once: a cache hit returns
 * the CloudFront URL; otherwise one caller atomically claims generation, makes
 * the sprite (Gemini image → chroma-key → downscale → quantize), uploads it, and
 * records it on SPECIES#<species>/BUDDY. Concurrent callers get 202 pending.
 *
 * Generation is bounded to species the caller actually grows (cost/abuse guard),
 * and the same key-protection as the AI proxy (the Gemini key stays server-side).
 */
const STALE_SECONDS = 300;

function buddyView(species: string, rec: BuddyRecord) {
  return {
    species,
    status: rec.status,
    sprite_url: rec.sprite_url ?? null,
    style_version: rec.style_version ?? STYLE_VERSION,
  };
}

export const handler = async (
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
): Promise<APIGatewayProxyResultV2> => {
  let sub: string;
  try {
    sub = getSub(event);
  } catch {
    return json(401, { error: 'Unauthorized' });
  }

  try {
    const body = parseJsonBody<{ species?: string }>(event);
    const species = normalizeSpecies(typeof body.species === 'string' ? body.species : '');
    if (!species) throw new ApiError(400, 'species is required');

    // Buds are only for species the caller actually grows (bounds AI image cost).
    const plants = await listPlants(sub);
    if (!plants.some((p) => p.species === species)) {
      throw new ApiError(403, 'No plant of that species in your garden');
    }

    const existing = await getBuddy(species);
    if (existing?.status === 'ready' && existing.sprite_url) {
      return json(200, buddyView(species, existing));
    }

    const staleBefore = Math.floor(Date.now() / 1000) - STALE_SECONDS;
    const claimed = await claimBuddyGeneration(species, STYLE_VERSION, staleBefore);
    if (!claimed) {
      // Someone else is generating (or just finished).
      const current = await getBuddy(species);
      if (current?.status === 'ready' && current.sprite_url) {
        return json(200, buddyView(species, current));
      }
      return json(202, { species, status: 'pending' });
    }

    try {
      const { data, mimeType } = await generateBuddyImage(species);
      const png = processSprite(data, mimeType);
      const key = spriteKey(species, STYLE_VERSION);
      await putSprite(key, png);
      const spriteUrl = `${requireEnv('SPRITE_CDN_BASE').replace(/\/$/, '')}/${key}`;
      await finalizeBuddy(species, spriteUrl, STYLE_VERSION);
      return json(201, {
        species,
        status: 'ready',
        sprite_url: spriteUrl,
        style_version: STYLE_VERSION,
      });
    } catch (genErr) {
      await failBuddy(species).catch(() => {});
      throw genErr;
    }
  } catch (err) {
    if (err instanceof SyntaxError) return json(400, { error: 'Invalid JSON body' });
    return toErrorResponse(err);
  }
};
