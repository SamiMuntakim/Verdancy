import { randomUUID } from 'node:crypto';
import type {
  APIGatewayProxyEventV2,
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyResultV2,
} from 'aws-lambda';
import { json, getSub, getEmailClaim, parseJsonBody } from '../lib/http';
import { ApiError, toErrorResponse } from '../lib/errors';
import { intEnv, nowIso } from '../lib/env';
import { normalizeSpecies } from '../lib/species';
import { userPk, plantSk, newImageKey, assertOwnsKey, plantIdFromKey } from '../lib/keys';
import {
  getMetadata,
  upsertUser,
  reserveSubscriberQuota,
  reserveFreeAi,
  putPlant,
  getPlant,
  listPlants,
  touchCare,
  listPhotos,
  putPhoto,
  deletePlantAndPhotos,
  recordMilestone,
  getTrees,
  getBuddiesForSpecies,
  type PlantRecord,
} from '../lib/dynamo';
import { presignPut, presignGet, deleteObjects } from '../lib/s3';
import { identify, diagnose } from '../lib/gemini';

const FREE_AI_LIFETIME_LIMIT = () => intEnv('FREE_AI_LIFETIME_LIMIT', 5);
const SUBSCRIBER_DAILY_AI_LIMIT = () => intEnv('SUBSCRIBER_DAILY_AI_LIMIT', 50);
// Defense-in-depth on cost: the app resizes to ~1MP (~250KB) before sending, so
// anything past ~5MB of base64 is rejected before we reserve quota or call Gemini.
const MAX_IMAGE_BASE64_CHARS = 7_000_000;

const asString = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);
const numOrNull = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v : null;

function pathParam(event: APIGatewayProxyEventV2, name: string): string {
  const value = event.pathParameters?.[name];
  if (typeof value !== 'string' || value.length === 0) {
    throw new ApiError(400, `Missing path parameter: ${name}`);
  }
  return value;
}

function plantView(item: PlantRecord): Record<string, unknown> {
  const plantId = typeof item.SK === 'string' ? item.SK.replace('PLANT#', '') : undefined;
  const view: Record<string, unknown> = { plantId };
  for (const [k, v] of Object.entries(item)) {
    if (k !== 'PK' && k !== 'SK') view[k] = v;
  }
  return view;
}

// ---------------------------------------------------------------------------
// Entitlement + quota — ALWAYS reserve before calling Gemini (invariant #3).
// ---------------------------------------------------------------------------
async function reserveAiQuota(sub: string): Promise<void> {
  const meta = await getMetadata(sub);
  if (meta?.blocked) throw new ApiError(403, 'Account is blocked');
  if (meta?.entitlement_active) {
    await reserveSubscriberQuota(sub, SUBSCRIBER_DAILY_AI_LIMIT());
  } else {
    await reserveFreeAi(sub, FREE_AI_LIFETIME_LIMIT());
  }
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------
async function handleUsers(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  await upsertUser(sub, getEmailClaim(event));
  return json(200, { ok: true });
}

async function handleUploads(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const body = parseJsonBody<{ kind?: string; plantId?: string }>(event);
  if (body.kind !== 'plant' && body.kind !== 'photo') {
    throw new ApiError(400, 'kind must be "plant" or "photo"');
  }
  let plantId: string;
  if (body.kind === 'photo') {
    plantId = asString(body.plantId) ?? '';
    if (!plantId) throw new ApiError(400, 'plantId is required for kind "photo"');
    if (!(await getPlant(sub, plantId))) throw new ApiError(404, 'Plant not found');
  } else {
    plantId = randomUUID(); // server mints the new plant's id (invariant #7)
  }
  const imageRef = newImageKey(sub, plantId);
  const uploadUrl = await presignPut(imageRef);
  return json(200, { image_ref: imageRef, upload_url: uploadUrl, plantId });
}

// Shared AI-proxy flow: validate the image, reserve quota BEFORE Gemini, then run.
async function aiProxy(
  sub: string,
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
  run: (image: string) => Promise<unknown>,
) {
  const body = parseJsonBody<{ image?: string }>(event);
  const image = asString(body.image);
  if (!image) throw new ApiError(400, 'Missing image');
  if (image.length > MAX_IMAGE_BASE64_CHARS) throw new ApiError(400, 'Image too large');
  await reserveAiQuota(sub); // reserve BEFORE Gemini; image forwarded then discarded
  return json(200, await run(image));
}

const handleIdentify = (sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) =>
  aiProxy(sub, event, identify);

const handleDiagnose = (sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) =>
  aiProxy(sub, event, diagnose);

async function handleCreatePlant(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const body = parseJsonBody<Record<string, unknown>>(event);
  assertOwnsKey(sub, body.image_ref); // 403 unless under the caller's prefix
  const imageRef = body.image_ref as string;
  const plantId = plantIdFromKey(imageRef);
  const item: PlantRecord = {
    PK: userPk(sub),
    SK: plantSk(plantId),
    common_name: asString(body.common_name) ?? 'Unknown Plant',
    species: normalizeSpecies(asString(body.species) ?? ''),
    nickname: asString(body.nickname) ?? null,
    image_ref: imageRef,
    toxicity: asString(body.toxicity) ?? 'High',
    lighting_needs: asString(body.lighting_needs) ?? null,
    fertilizer_info: asString(body.fertilizer_info) ?? null,
    confidence: asString(body.confidence) ?? null,
    care: {
      water: { cadence_days: numOrNull(body.water_cadence_days), last_done_at: null },
      fertilize: { cadence_days: numOrNull(body.fertilize_cadence_days), last_done_at: null },
      prune: { cadence_days: null, last_done_at: null },
    },
    created_at: nowIso(),
  };
  await putPlant(item);
  return json(201, plantView(item));
}

async function handleListPlants(sub: string) {
  const plants = await listPlants(sub);
  const speciesList = plants
    .map((p) => (typeof p.species === 'string' ? p.species : ''))
    .filter(Boolean);
  const buddies = speciesList.length > 0 ? await getBuddiesForSpecies(speciesList) : {};
  const items = await Promise.all(
    plants.map(async (p) => ({
      ...plantView(p),
      download_url: typeof p.image_ref === 'string' ? await presignGet(p.image_ref) : null,
      buddy: typeof p.species === 'string' ? (buddies[p.species] ?? null) : null,
    })),
  );
  return json(200, { plants: items });
}

async function handleCare(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const plantId = pathParam(event, 'plantId');
  const body = parseJsonBody<{ type?: string }>(event);
  if (body.type !== 'water' && body.type !== 'fertilize' && body.type !== 'prune') {
    throw new ApiError(400, 'type must be "water", "fertilize", or "prune"');
  }
  await touchCare(sub, plantId, body.type); // 404 if the plant isn't the caller's
  return json(200, { ok: true });
}

async function handleDeletePlant(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const plantId = pathParam(event, 'plantId');
  const plant = await getPlant(sub, plantId);
  if (!plant) throw new ApiError(404, 'Plant not found');
  const photos = await listPhotos(sub, plantId);

  const keys: string[] = [];
  if (typeof plant.image_ref === 'string') keys.push(plant.image_ref);
  for (const photo of photos) {
    if (typeof photo.image_ref === 'string') keys.push(photo.image_ref);
  }
  await deleteObjects(keys); // S3 first, then the records
  await deletePlantAndPhotos(
    sub,
    plantId,
    photos.map((p) => String(p.SK)),
  );
  return json(200, { ok: true });
}

async function handleAddPhoto(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const plantId = pathParam(event, 'plantId');
  if (!(await getPlant(sub, plantId))) throw new ApiError(404, 'Plant not found');
  const body = parseJsonBody<{ image_ref?: string; caption?: string }>(event);
  assertOwnsKey(sub, body.image_ref);
  if (plantIdFromKey(body.image_ref) !== plantId) {
    throw new ApiError(400, 'image_ref does not belong to this plant');
  }
  const ts = nowIso();
  await putPhoto(sub, plantId, ts, {
    image_ref: body.image_ref,
    taken_at: ts,
    caption: asString(body.caption) ?? null,
  });
  return json(201, { ok: true, taken_at: ts });
}

async function handleListPhotos(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const plantId = pathParam(event, 'plantId');
  if (!(await getPlant(sub, plantId))) throw new ApiError(404, 'Plant not found');
  const photos = await listPhotos(sub, plantId);
  const items = await Promise.all(
    photos.map(async (ph) => ({
      taken_at: ph.taken_at,
      caption: ph.caption,
      download_url: typeof ph.image_ref === 'string' ? await presignGet(ph.image_ref) : null,
    })),
  );
  return json(200, { photos: items });
}

async function handleMilestone(sub: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const body = parseJsonBody<{ milestoneId?: string }>(event);
  const milestoneId = asString(body.milestoneId);
  if (!milestoneId) throw new ApiError(400, 'milestoneId is required');
  return json(200, await recordMilestone(sub, milestoneId));
}

async function handleGetTrees(sub: string) {
  return json(200, await getTrees(sub));
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------
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
    switch (event.routeKey) {
      case 'POST /users':
        return await handleUsers(sub, event);
      case 'POST /uploads':
        return await handleUploads(sub, event);
      case 'POST /identify':
        return await handleIdentify(sub, event);
      case 'POST /diagnose':
        return await handleDiagnose(sub, event);
      case 'POST /plants':
        return await handleCreatePlant(sub, event);
      case 'GET /plants':
        return await handleListPlants(sub);
      case 'POST /plants/{plantId}/care':
        return await handleCare(sub, event);
      case 'DELETE /plants/{plantId}':
        return await handleDeletePlant(sub, event);
      case 'POST /plants/{plantId}/photos':
        return await handleAddPhoto(sub, event);
      case 'GET /plants/{plantId}/photos':
        return await handleListPhotos(sub, event);
      case 'POST /milestones':
        return await handleMilestone(sub, event);
      case 'GET /me/trees':
        return await handleGetTrees(sub);
      default:
        return json(404, { error: 'Not Found' });
    }
  } catch (err) {
    if (err instanceof SyntaxError) return json(400, { error: 'Invalid JSON body' });
    return toErrorResponse(err);
  }
};
