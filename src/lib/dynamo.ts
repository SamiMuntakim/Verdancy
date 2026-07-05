import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
  BatchWriteCommand,
  BatchGetCommand,
  type QueryCommandOutput,
} from '@aws-sdk/lib-dynamodb';
import { ApiError } from './errors';
import { requireEnv, nowIso, todayUtc, quotaTtlEpoch } from './env';
import {
  userPk,
  META_SK,
  plantSk,
  photoSk,
  photoSkPrefix,
  quotaSk,
  speciesPk,
  BUDDY_SK,
  refCodePk,
  REF_OWNER_SK,
} from './keys';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});

const table = (): string => requireEnv('TABLE_NAME');

function isConditionalFailure(err: unknown): boolean {
  return err instanceof Error && err.name === 'ConditionalCheckFailedException';
}

// ---------------------------------------------------------------------------
// Profile / entitlement
// ---------------------------------------------------------------------------

export interface UserMetadata {
  email?: string;
  blocked?: boolean;
  entitlement_active?: boolean;
  entitlement_expires_at?: number | null;
  free_ai_used?: number;
  trees_pledged?: number;
  milestones?: Set<string> | string[];
  referral_code?: string;
  referred_by?: string;
  referral_credited?: boolean;
}

export async function getMetadata(sub: string): Promise<UserMetadata | undefined> {
  const res = await ddb.send(
    new GetCommand({ TableName: table(), Key: { PK: userPk(sub), SK: META_SK } }),
  );
  return res.Item as UserMetadata | undefined;
}

/** Idempotent profile upsert — seeds counters/flags without clobbering them. */
export async function upsertUser(sub: string, email: string | undefined): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: table(),
      Key: { PK: userPk(sub), SK: META_SK },
      UpdateExpression:
        'SET created_at = if_not_exists(created_at, :now), ' +
        'free_ai_used = if_not_exists(free_ai_used, :zero), ' +
        'trees_pledged = if_not_exists(trees_pledged, :zero), ' +
        'entitlement_active = if_not_exists(entitlement_active, :false), ' +
        'blocked = if_not_exists(blocked, :false)' +
        (email ? ', email = :email' : ''),
      ExpressionAttributeValues: {
        ':now': nowIso(),
        ':zero': 0,
        ':false': false,
        ...(email ? { ':email': email } : {}),
      },
    }),
  );
}

/** RevenueCat webhook entitlement write (PK = `USER#<appUserID>` = `USER#<sub>`). */
export async function setEntitlement(
  appUserId: string,
  active: boolean,
  expiresAt: number | null,
): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: table(),
      Key: { PK: userPk(appUserId), SK: META_SK },
      UpdateExpression:
        'SET entitlement_active = :active, entitlement_expires_at = :exp, ' +
        'created_at = if_not_exists(created_at, :now), ' +
        'free_ai_used = if_not_exists(free_ai_used, :zero), ' +
        'trees_pledged = if_not_exists(trees_pledged, :zero), ' +
        'blocked = if_not_exists(blocked, :false)',
      ExpressionAttributeValues: {
        ':active': active,
        ':exp': expiresAt,
        ':now': nowIso(),
        ':zero': 0,
        ':false': false,
      },
    }),
  );
}

// ---------------------------------------------------------------------------
// Quota reservation — ALWAYS before calling Gemini (hard invariant #3).
// ---------------------------------------------------------------------------

/**
 * Subscriber daily cap. Atomic `ADD count :one` on the date-keyed quota item,
 * allowed only while under the limit. Throws 429 on the conditional failure.
 * The date lives in the key, so day-rollover is automatic and race-free; the
 * item TTLs away.
 */
export async function reserveSubscriberQuota(sub: string, dailyLimit: number): Promise<void> {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: quotaSk(todayUtc()) },
        UpdateExpression: 'SET expires_at = if_not_exists(expires_at, :ttl) ADD #count :one',
        ConditionExpression: 'attribute_not_exists(#count) OR #count < :limit',
        ExpressionAttributeNames: { '#count': 'count' },
        ExpressionAttributeValues: { ':one': 1, ':ttl': quotaTtlEpoch(), ':limit': dailyLimit },
      }),
    );
  } catch (err) {
    if (isConditionalFailure(err)) throw new ApiError(429, 'Daily AI limit reached');
    throw err;
  }
}

/**
 * Non-subscriber lifetime free allowance. Atomic `ADD free_ai_used :one` on the
 * METADATA item, allowed only while under the limit. Throws 402 on the
 * conditional failure (client shows the paywall). The `attribute_not_exists`
 * branch handles a cold profile so the first free call isn't wrongly rejected.
 */
export async function reserveFreeAi(sub: string, freeLimit: number): Promise<void> {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: META_SK },
        UpdateExpression: 'ADD free_ai_used :one',
        ConditionExpression: 'attribute_not_exists(free_ai_used) OR free_ai_used < :limit',
        ExpressionAttributeValues: { ':one': 1, ':limit': freeLimit },
      }),
    );
  } catch (err) {
    if (isConditionalFailure(err)) throw new ApiError(402, 'Free allowance exhausted');
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Plants & photos
// ---------------------------------------------------------------------------

export interface PlantRecord {
  PK: string;
  SK: string;
  [key: string]: unknown;
}

export async function putPlant(item: PlantRecord): Promise<void> {
  await ddb.send(new PutCommand({ TableName: table(), Item: item }));
}

export async function getPlant(sub: string, plantId: string): Promise<PlantRecord | undefined> {
  const res = await ddb.send(
    new GetCommand({ TableName: table(), Key: { PK: userPk(sub), SK: plantSk(plantId) } }),
  );
  return res.Item as PlantRecord | undefined;
}

export async function listPlants(sub: string): Promise<PlantRecord[]> {
  const res = await ddb.send(
    new QueryCommand({
      TableName: table(),
      KeyConditionExpression: 'PK = :pk AND begins_with(SK, :p)',
      ExpressionAttributeValues: { ':pk': userPk(sub), ':p': 'PLANT#' },
    }),
  );
  return (res.Items ?? []) as PlantRecord[];
}

/**
 * Update `care.<type>.last_done_at`. Conditioned on the item existing — since the
 * PK is scoped to the caller, a missing item means the plant isn't theirs → 404.
 */
export async function touchCare(sub: string, plantId: string, type: string): Promise<void> {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: plantSk(plantId) },
        UpdateExpression: 'SET care.#t.last_done_at = :now',
        ConditionExpression: 'attribute_exists(SK)',
        ExpressionAttributeNames: { '#t': type },
        ExpressionAttributeValues: { ':now': nowIso() },
      }),
    );
  } catch (err) {
    if (isConditionalFailure(err)) throw new ApiError(404, 'Plant not found');
    throw err;
  }
}

export interface PlantUpdates {
  nickname?: string | null;
  waterCadenceDays?: number | null;
  fertilizeCadenceDays?: number | null;
  pruneCadenceDays?: number | null;
}

/**
 * Edit a plant (rename / adjust cadences). Only provided fields change; a `null`
 * cadence clears that schedule. Conditioned on the item existing under the caller's
 * PK → 404 if it isn't theirs. Throws 400 if nothing was provided.
 */
export async function updatePlant(
  sub: string,
  plantId: string,
  updates: PlantUpdates,
): Promise<PlantRecord> {
  const sets: string[] = [];
  const values: Record<string, unknown> = {};
  if (updates.nickname !== undefined) {
    sets.push('nickname = :nick');
    values[':nick'] = updates.nickname;
  }
  if (updates.waterCadenceDays !== undefined) {
    sets.push('care.water.cadence_days = :w');
    values[':w'] = updates.waterCadenceDays;
  }
  if (updates.fertilizeCadenceDays !== undefined) {
    sets.push('care.fertilize.cadence_days = :f');
    values[':f'] = updates.fertilizeCadenceDays;
  }
  if (updates.pruneCadenceDays !== undefined) {
    sets.push('care.prune.cadence_days = :p');
    values[':p'] = updates.pruneCadenceDays;
  }
  if (sets.length === 0) throw new ApiError(400, 'No fields to update');

  try {
    const res = await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: plantSk(plantId) },
        UpdateExpression: 'SET ' + sets.join(', '),
        ConditionExpression: 'attribute_exists(SK)',
        ExpressionAttributeValues: values,
        ReturnValues: 'ALL_NEW',
      }),
    );
    return res.Attributes as PlantRecord;
  } catch (err) {
    if (isConditionalFailure(err)) throw new ApiError(404, 'Plant not found');
    throw err;
  }
}

export async function listPhotos(sub: string, plantId: string): Promise<PlantRecord[]> {
  const res = await ddb.send(
    new QueryCommand({
      TableName: table(),
      KeyConditionExpression: 'PK = :pk AND begins_with(SK, :p)',
      ExpressionAttributeValues: { ':pk': userPk(sub), ':p': photoSkPrefix(plantId) },
    }),
  );
  return (res.Items ?? []) as PlantRecord[];
}

export async function putPhoto(
  sub: string,
  plantId: string,
  ts: string,
  item: Record<string, unknown>,
): Promise<void> {
  await ddb.send(
    new PutCommand({
      TableName: table(),
      Item: { PK: userPk(sub), SK: photoSk(plantId, ts), ...item },
    }),
  );
}

/** Delete the plant item + all its photo items (batched in 25s). */
export async function deletePlantAndPhotos(
  sub: string,
  plantId: string,
  photoSks: string[],
): Promise<void> {
  const sks = [plantSk(plantId), ...photoSks];
  for (let i = 0; i < sks.length; i += 25) {
    const chunk = sks.slice(i, i + 25);
    await ddb.send(
      new BatchWriteCommand({
        RequestItems: {
          [table()]: chunk.map((sk) => ({
            DeleteRequest: { Key: { PK: userPk(sub), SK: sk } },
          })),
        },
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Milestones & trees
// ---------------------------------------------------------------------------

export interface TreesView {
  trees_pledged: number;
  milestones: string[];
}

function toMilestoneArray(value: Set<string> | string[] | undefined): string[] {
  if (!value) return [];
  return Array.isArray(value) ? value : Array.from(value);
}

/**
 * ONE atomic conditional UpdateItem (hard invariant #5): add the milestone id to
 * the set and increment `trees_pledged`, only if the id isn't already present.
 * A duplicate fails the condition → the entire write is rejected, so the counter
 * increments exactly once even under concurrent double-submits.
 */
export async function recordMilestone(sub: string, milestoneId: string): Promise<TreesView> {
  try {
    const res = await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: META_SK },
        UpdateExpression: 'ADD milestones :midSet, trees_pledged :one',
        ConditionExpression: 'NOT contains(milestones, :mid)',
        ExpressionAttributeValues: {
          ':midSet': new Set([milestoneId]),
          ':mid': milestoneId,
          ':one': 1,
        },
        ReturnValues: 'ALL_NEW',
      }),
    );
    const attrs = res.Attributes as UserMetadata | undefined;
    return {
      trees_pledged: (attrs?.trees_pledged as number) ?? 0,
      milestones: toMilestoneArray(attrs?.milestones),
    };
  } catch (err) {
    if (isConditionalFailure(err)) {
      // Already counted — idempotent. Return the current view.
      return getTrees(sub);
    }
    throw err;
  }
}

export async function getTrees(sub: string): Promise<TreesView> {
  const meta = await getMetadata(sub);
  return {
    trees_pledged: (meta?.trees_pledged as number) ?? 0,
    milestones: toMilestoneArray(meta?.milestones),
  };
}

// ---------------------------------------------------------------------------
// Plant Buddy — one shared SPECIES#<species>/BUDDY item, generated once.
// ---------------------------------------------------------------------------

export interface BuddyRecord {
  status: 'pending' | 'ready' | 'failed';
  sprite_url?: string;
  style_version?: number;
  created_at?: string;
}

export async function getBuddy(species: string): Promise<BuddyRecord | undefined> {
  const res = await ddb.send(
    new GetCommand({ TableName: table(), Key: { PK: speciesPk(species), SK: BUDDY_SK } }),
  );
  return res.Item as BuddyRecord | undefined;
}

/**
 * Atomically claim the right to generate this species' sprite. Succeeds only if
 * no item exists yet, the last attempt failed, or a prior `pending` claim is
 * stale (a crashed/timed-out generation). Concurrent callers: exactly one wins;
 * the rest get `false` (someone else is generating, or it's already ready).
 */
export async function claimBuddyGeneration(
  species: string,
  styleVersion: number,
  staleBeforeEpoch: number,
): Promise<boolean> {
  try {
    await ddb.send(
      new PutCommand({
        TableName: table(),
        Item: {
          PK: speciesPk(species),
          SK: BUDDY_SK,
          status: 'pending',
          style_version: styleVersion,
          claimed_at: Math.floor(Date.now() / 1000),
        },
        ConditionExpression:
          'attribute_not_exists(SK) OR #s = :failed OR (#s = :pending AND claimed_at < :stale)',
        ExpressionAttributeNames: { '#s': 'status' },
        ExpressionAttributeValues: {
          ':failed': 'failed',
          ':pending': 'pending',
          ':stale': staleBeforeEpoch,
        },
      }),
    );
    return true;
  } catch (err) {
    if (isConditionalFailure(err)) return false;
    throw err;
  }
}

export async function finalizeBuddy(
  species: string,
  spriteUrl: string,
  styleVersion: number,
): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: table(),
      Key: { PK: speciesPk(species), SK: BUDDY_SK },
      UpdateExpression:
        'SET #s = :ready, sprite_url = :url, style_version = :sv, ' +
        'created_at = if_not_exists(created_at, :now)',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: {
        ':ready': 'ready',
        ':url': spriteUrl,
        ':sv': styleVersion,
        ':now': nowIso(),
      },
    }),
  );
}

/** Best-effort: mark a failed generation so it can be retried (don't clobber ready). */
export async function failBuddy(species: string): Promise<void> {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: speciesPk(species), SK: BUDDY_SK },
        UpdateExpression: 'SET #s = :failed',
        ConditionExpression: '#s = :pending',
        ExpressionAttributeNames: { '#s': 'status' },
        ExpressionAttributeValues: { ':failed': 'failed', ':pending': 'pending' },
      }),
    );
  } catch (err) {
    if (!isConditionalFailure(err)) throw err;
  }
}

/** Resolve buddy state for a set of species (for GET /plants). */
export async function getBuddiesForSpecies(
  speciesList: string[],
): Promise<Record<string, BuddyRecord>> {
  const unique = [...new Set(speciesList.filter((s) => s))];
  const out: Record<string, BuddyRecord> = {};
  for (let i = 0; i < unique.length; i += 100) {
    const chunk = unique.slice(i, i + 100);
    const res = await ddb.send(
      new BatchGetCommand({
        RequestItems: {
          [table()]: { Keys: chunk.map((s) => ({ PK: speciesPk(s), SK: BUDDY_SK })) },
        },
      }),
    );
    for (const item of res.Responses?.[table()] ?? []) {
      const species = String(item.PK).replace('SPECIES#', '');
      out[species] = {
        status: item.status,
        sprite_url: item.sprite_url,
        style_version: item.style_version,
        created_at: item.created_at,
      };
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Referral loop (iOS-PRD §10): "invite a friend — a tree for both of you."
// The code→owner mapping is a direct-lookup REFCODE# item (no GSI needed).
// ---------------------------------------------------------------------------

// Unambiguous alphabet (no 0/O/1/I/L) for typeable invite codes.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

function generateCode(length = 8): string {
  let out = '';
  for (let i = 0; i < length; i += 1) {
    out += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  return out;
}

/**
 * Return the caller's invite code, minting one on first use. The REFCODE item is
 * claimed with a conditional put (collision-safe); METADATA takes the code via
 * if_not_exists, so a concurrent race converges on a single stored code.
 */
export async function getOrCreateReferralCode(sub: string): Promise<string> {
  const meta = await getMetadata(sub);
  if (meta?.referral_code) return meta.referral_code;

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const code = generateCode();
    try {
      await ddb.send(
        new PutCommand({
          TableName: table(),
          Item: { PK: refCodePk(code), SK: REF_OWNER_SK, sub, created_at: nowIso() },
          ConditionExpression: 'attribute_not_exists(PK)',
        }),
      );
    } catch (err) {
      if (isConditionalFailure(err)) continue; // collision — try another code
      throw err;
    }
    const res = await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: META_SK },
        UpdateExpression: 'SET referral_code = if_not_exists(referral_code, :c)',
        ExpressionAttributeValues: { ':c': code },
        ReturnValues: 'ALL_NEW',
      }),
    );
    // If a concurrent request won, both codes map to this sub — harmless.
    return (res.Attributes?.referral_code as string) ?? code;
  }
  throw new ApiError(500, 'Could not allocate an invite code');
}

/** Resolve an invite code to its owner's sub, or undefined. */
export async function getReferralOwner(code: string): Promise<string | undefined> {
  const res = await ddb.send(
    new GetCommand({ TableName: table(), Key: { PK: refCodePk(code), SK: REF_OWNER_SK } }),
  );
  return res.Item?.sub as string | undefined;
}

/** Record who referred this user — once, ever. Throws 400 on a second attempt. */
export async function setReferredBy(sub: string, inviterSub: string): Promise<void> {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: META_SK },
        UpdateExpression: 'SET referred_by = :inviter',
        ConditionExpression: 'attribute_not_exists(referred_by)',
        ExpressionAttributeValues: { ':inviter': inviterSub },
      }),
    );
  } catch (err) {
    if (isConditionalFailure(err)) throw new ApiError(400, 'An invite code was already applied');
    throw err;
  }
}

/**
 * Atomically claim the one-time referral credit for this user's conversion.
 * Returns true exactly once (webhook retries / duplicate events get false).
 */
export async function markReferralCredited(sub: string): Promise<boolean> {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: table(),
        Key: { PK: userPk(sub), SK: META_SK },
        UpdateExpression: 'SET referral_credited = :true',
        ConditionExpression: 'attribute_not_exists(referral_credited)',
        ExpressionAttributeValues: { ':true': true },
      }),
    );
    return true;
  } catch (err) {
    if (isConditionalFailure(err)) return false;
    throw err;
  }
}

/** Remove the code→owner mapping (account deletion cleanup). */
export async function deleteReferralCode(code: string): Promise<void> {
  await ddb.send(
    new BatchWriteCommand({
      RequestItems: {
        [table()]: [{ DeleteRequest: { Key: { PK: refCodePk(code), SK: REF_OWNER_SK } } }],
      },
    }),
  );
}

// ---------------------------------------------------------------------------
// Account deletion — remove every item under USER#<sub> (App Store 5.1.1(v)).
// ---------------------------------------------------------------------------

export async function deleteAllUserItems(sub: string): Promise<void> {
  const keys: Array<{ PK: string; SK: string }> = [];
  let startKey: QueryCommandOutput['LastEvaluatedKey'];
  do {
    const res = await ddb.send(
      new QueryCommand({
        TableName: table(),
        KeyConditionExpression: 'PK = :pk',
        ExpressionAttributeValues: { ':pk': userPk(sub) },
        ProjectionExpression: 'PK, SK',
        ExclusiveStartKey: startKey,
      }),
    );
    for (const item of res.Items ?? []) {
      keys.push({ PK: String(item.PK), SK: String(item.SK) });
    }
    startKey = res.LastEvaluatedKey;
  } while (startKey);

  for (let i = 0; i < keys.length; i += 25) {
    const chunk = keys.slice(i, i + 25);
    await ddb.send(
      new BatchWriteCommand({
        RequestItems: { [table()]: chunk.map((Key) => ({ DeleteRequest: { Key } })) },
      }),
    );
  }
}
