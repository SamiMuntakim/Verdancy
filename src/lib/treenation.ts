import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { floatEnv, intEnv } from './env';

/**
 * Tree-Nation planting client (`POST /api/plant`). Spends real tree credits.
 *
 * **`species_id` is honored — as long as the species is in stock.** Verified
 * against the live API 2026-08: requesting in-stock 3656 planted exactly 3656,
 * while an earlier request for 1342 (which had gone to `stock: 0`) was
 * substituted. So stock, not the parameter, is what decides whether we get what
 * we ask for — and we ask for the cheapest species that is in stock right now,
 * recomputed per plant rather than hardcoded.
 *
 * Layers, all fail-safe (uncertainty → don't spend):
 *  1. Ask for the cheapest in-stock species, which must be within
 *     `TARGET_TREE_PRICE_EUR` — the price we intend to pay.
 *  2. Refuse to plant if the DEAREST in-stock species exceeds
 *     `MAX_TREE_PRICE_EUR`, bounding what a mid-flight stock-out substitution
 *     could cost.
 *  3. Log loudly on a substitution and drop the stale listing, so paying above
 *     the floor is visible immediately rather than at invoice time.
 *  4. The caller reserves a global daily budget (circuit breaker) first, and
 *     claims an atomic milestone before spending (exactly-once).
 *
 * The token is loaded from Secrets Manager (cached), mirroring the webhook secret.
 * Node 20 provides global `fetch`.
 */

const API_BASE = process.env.TREENATION_API_BASE ?? 'https://tree-nation.com';

const secretsClient = new SecretsManagerClient({});
let cachedToken: string | undefined;

async function getApiToken(): Promise<string> {
  if (cachedToken !== undefined) return cachedToken;
  const secretId = process.env.TREENATION_API_TOKEN_SECRET_NAME;
  if (!secretId) throw new Error('TREENATION_API_TOKEN_SECRET_NAME is not set');
  const res = await secretsClient.send(new GetSecretValueCommand({ SecretId: secretId }));
  if (!res.SecretString) throw new Error('Tree-Nation token has no SecretString value');
  cachedToken = res.SecretString.trim();
  return cachedToken;
}

/** The project Tree-Nation plants our trees from (default 269, Mkussu Forest). */
function projectId(): number {
  return intEnv('TREENATION_PROJECT_ID', 269);
}

/**
 * The price we intend to pay: the cheapest in-stock species must be at or under
 * this, or we don't plant at all (default €0.35, project 269's floor).
 */
function targetTreePrice(): number {
  return floatEnv('TARGET_TREE_PRICE_EUR', 0.35);
}

/**
 * Substitution tolerance. We choose the species and Tree-Nation honors it
 * (verified), but if our pick stocks out between listing and plant they
 * substitute — so this bounds what such a substitution may cost (default
 * €0.50, the dearest in-stock species in project 269). If anything pricier is
 * in stock, we stop planting rather than risk it.
 */
function maxTreePrice(): number {
  return floatEnv('MAX_TREE_PRICE_EUR', 0.5);
}

interface Species {
  id: number;
  name?: string;
  price: number;
  stock: number;
}

export interface ProjectPricing {
  /** Cheapest IN-STOCK species — the one we ask Tree-Nation to plant. */
  cheapest: Species;
  /** Dearest in-stock price — what a tree could cost if our pick is ignored. */
  worstCase: number;
}

// Cache the project lookup so we don't hit the species endpoint on every plant,
// but refresh often enough to notice a price change or a stock-out.
let projectCache: { id: number; pricing: ProjectPricing | null; at: number } | undefined;
const PROJECT_TTL_MS = 60 * 60 * 1000; // 1h

/**
 * Live pricing for the project: the cheapest in-stock species (what we request)
 * and the dearest in-stock price (what we could be charged if the request is
 * ignored). Returns null if it can't be determined — network failure, malformed
 * payload, or nothing in stock at all — so the caller refuses to spend.
 *
 * Only `stock > 0` species count: an out-of-stock species can't be planted, and
 * asking for one is what made Tree-Nation substitute a species of its choosing.
 */
export async function fetchProjectPricing(id = projectId()): Promise<ProjectPricing | null> {
  if (projectCache && projectCache.id === id && Date.now() - projectCache.at < PROJECT_TTL_MS) {
    return projectCache.pricing;
  }
  try {
    const res = await fetch(`${API_BASE}/api/projects/${id}/species`);
    if (!res.ok) return null;
    const data = (await res.json()) as unknown;
    if (!Array.isArray(data) || data.length === 0) return null;

    let cheapest: Species | null = null;
    let worstCase: number | null = null;
    for (const raw of data as Species[]) {
      const price = Number(raw?.price);
      const stock = Number(raw?.stock);
      const speciesId = Number(raw?.id);
      // A malformed entry could hide a real price — refuse rather than guess.
      if (!Number.isFinite(price) || !Number.isFinite(stock) || !Number.isFinite(speciesId)) {
        return null;
      }
      if (stock <= 0) continue;
      if (!cheapest || price < cheapest.price) {
        cheapest = { id: speciesId, name: raw?.name, price, stock };
      }
      worstCase = worstCase === null ? price : Math.max(worstCase, price);
    }
    const pricing = cheapest && worstCase !== null ? { cheapest, worstCase } : null;
    projectCache = { id, pricing, at: Date.now() };
    return pricing;
  } catch {
    return null;
  }
}

/**
 * Fail-safe price guard, both halves of which must hold:
 *  - the species we're about to request costs at most `TARGET_TREE_PRICE_EUR`;
 *  - and a substitution (only possible if our pick stocks out mid-flight) can
 *    cost at most `MAX_TREE_PRICE_EUR`.
 *
 * Any uncertainty — lookup failed, a malformed entry, nothing in stock, or
 * either threshold exceeded — returns false and the caller must not plant.
 */
export async function withinBudget(): Promise<boolean> {
  const pricing = await fetchProjectPricing();
  if (!pricing) return false; // can't verify → don't spend
  return pricing.cheapest.price <= targetTreePrice() && pricing.worstCase <= maxTreePrice();
}

export interface PlantedTree {
  id: number;
  token: string;
  collect_url: string;
  certificate_url: string;
  species_id?: number;
  species_name?: string;
  project_id?: number;
  project_name?: string;
  /** The project's public field-updates page (photos from the ground). */
  project_url?: string;
  country?: string;
  species_life_time_CO2?: number;
  // Enriched from the public species endpoint after planting (best-effort):
  /** Friendly species name, e.g. "Grey Mangrove" for Avicennia marina. */
  common_name?: string;
  /** Photo of the species, from Tree-Nation's public species detail. */
  species_image?: string;
}

// ---------------------------------------------------------------------------
// Species enrichment — the public species endpoint (no auth) carries a real
// photo and a friendly common name. Purely cosmetic, so every failure here is
// swallowed: a tree with no picture is still a tree.
// ---------------------------------------------------------------------------

interface SpeciesDetail {
  image?: string;
  common_name?: string;
}

const speciesDetailCache = new Map<number, SpeciesDetail>();

async function fetchSpeciesDetail(id: number): Promise<SpeciesDetail> {
  const cached = speciesDetailCache.get(id);
  if (cached) return cached;
  try {
    const res = await fetch(`${API_BASE}/api/species/${id}`);
    if (!res.ok) return {};
    const data = (await res.json()) as { image?: unknown; common_names?: unknown };
    const detail: SpeciesDetail = {
      image: typeof data.image === 'string' ? data.image : undefined,
      // `common_names` can be comma-separated ("Grey Mangrove, White Mangrove").
      common_name:
        typeof data.common_names === 'string' && data.common_names.trim()
          ? data.common_names.split(',')[0].trim()
          : undefined,
    };
    speciesDetailCache.set(id, detail);
    return detail;
  } catch {
    return {};
  }
}

/** Attach species photo + common name to each planted tree (best-effort). */
async function enrichTrees(trees: PlantedTree[]): Promise<PlantedTree[]> {
  const ids = [...new Set(trees.map((t) => t.species_id).filter((id): id is number => !!id))];
  const details = new Map<number, SpeciesDetail>();
  await Promise.all(ids.map(async (id) => details.set(id, await fetchSpeciesDetail(id))));
  return trees.map((t) => {
    const d = t.species_id ? details.get(t.species_id) : undefined;
    return d ? { ...t, species_image: d.image, common_name: d.common_name } : t;
  });
}

export interface PlantResult {
  trees: PlantedTree[];
  payment_id?: number;
}

/**
 * Plant `quantity` trees. Returns null WITHOUT spending if the price guard fails.
 * Throws on an actual API error (so the caller's retry/reconcile can handle it) —
 * but note the guard makes over-price spending impossible, not just unlikely.
 *
 * `internalId` (our opaque user id) is passed as the recipient id; no email is
 * sent to Tree-Nation, so no user PII leaves our system. The returned
 * collect/certificate URLs are the user's in-app reward.
 */
export async function plantTrees(opts: {
  internalId: string;
  quantity: number;
  message?: string;
}): Promise<PlantResult | null> {
  if (opts.quantity <= 0) return { trees: [] };

  const pricing = await fetchProjectPricing();
  if (!pricing) {
    console.error('Tree-Nation: cannot verify pricing — not planting');
    return null;
  }
  if (pricing.cheapest.price > targetTreePrice()) {
    console.error(
      `Tree-Nation: cheapest in-stock species costs ${pricing.cheapest.price}, ` +
        `above the ${targetTreePrice()} target — not planting`,
    );
    return null;
  }
  if (pricing.worstCase > maxTreePrice()) {
    console.error(
      `Tree-Nation: an in-stock species costs ${pricing.worstCase}, above the ` +
        `${maxTreePrice()} substitution ceiling — not planting`,
    );
    return null;
  }

  const token = await getApiToken();
  // Ask for the CHEAPEST in-stock species. Tree-Nation substitutes a species of
  // its own choosing when the requested one has no stock (that's what happened
  // when we pinned a fixed id and its stock ran out), so the id is recomputed
  // from live stock on every plant rather than hardcoded.
  const body: Record<string, unknown> = {
    recipients: [{ internal_id: opts.internalId }],
    quantity: opts.quantity,
    species_id: pricing.cheapest.id,
    language: 'en',
  };
  if (opts.message) body.message = opts.message;

  const res = await fetch(`${API_BASE}/api/plant`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`Tree-Nation plant failed: HTTP ${res.status}`);
  }
  const data = (await res.json()) as { trees?: PlantedTree[]; payment_id?: number };
  const trees = data.trees ?? [];

  // Did we get what we asked for? Money is already spent either way, but a
  // silent substitution means we're paying above the cheapest rate, and we
  // want that visible rather than buried in an invoice at the end of the month.
  const substituted = trees.find((t) => t.species_id && t.species_id !== pricing.cheapest.id);
  if (substituted) {
    console.error(
      `Tree-Nation substituted species: asked ${pricing.cheapest.id} ` +
        `(${pricing.cheapest.name ?? '?'} at ${pricing.cheapest.price}), ` +
        `got ${substituted.species_id} (${substituted.species_name ?? '?'})`,
    );
    // A substitution means our pick stocked out, so the cached listing is stale.
    // Drop it: the next plant re-reads live stock and picks a species that
    // actually exists, instead of repeating the same doomed request for an hour.
    projectCache = undefined;
  }
  return { trees: await enrichTrees(trees), payment_id: data.payment_id };
}

/** Test-only: reset caches between unit tests. */
export function _resetTreeNationCachesForTest(): void {
  cachedToken = undefined;
  projectCache = undefined;
  speciesDetailCache.clear();
}

// ---------------------------------------------------------------------------
// Community forest — Tree-Nation's PUBLIC profile feed (no auth, no credits).
//
// This is the whole app's forest: every tree Verdancy has ever planted, as
// Tree-Nation themselves report it. We proxy rather than letting the app call
// them directly, so the shape stays ours, one slow third party can't stall the
// client, and a change on their side is a server fix rather than an app release.
// ---------------------------------------------------------------------------

const BFF_HEADERS = { 'X-API-VERSION': '1', Accept: 'application/json' };

/** Our public profile slug and numeric owner id on Tree-Nation. */
const profileSlug = (): string => process.env.TREENATION_PROFILE_SLUG ?? 'verdancy';
const ownerId = (): number => intEnv('TREENATION_OWNER_ID', 992563);

export interface CommunityTree {
  id: number;
  quantity: number;
  /** Tree-Nation's own sentence, e.g. "These 2 Albizia gummifera are growing…". */
  message: string | null;
  image: string | null;
  planted_at: string | null;
  certificate_url: string;
  collect_url: string;
}

export interface CommunityForest {
  total_trees: number;
  co2_tons: number;
  profile_url: string;
  trees: CommunityTree[];
}

let communityCache: { data: CommunityForest; at: number } | undefined;
const COMMUNITY_TTL_MS = 15 * 60 * 1000;

async function bff<T>(path: string): Promise<T | null> {
  try {
    const res = await fetch(`${API_BASE}${path}`, { headers: BFF_HEADERS });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

/** Hard stop on paging, so a large forest can't turn one request into hundreds. */
const MAX_FEED_PAGES = 10;

/**
 * Walk the whole feed rather than just page 1, so the earliest plantings stay
 * visible as the forest grows instead of falling off the end.
 *
 * Their `meta.is_last_page` can't be trusted — an empty page 2 still reports
 * `false` — so an empty `data` array is what ends the walk. Pages are fetched in
 * sequence because we only continue when the previous one had content.
 */
async function fetchAllFeedPages(id: number): Promise<Array<Record<string, unknown>>> {
  const base =
    `ownerIds%5B%5D=${id}&sponsorId=${id}&planterIds%5B%5D=${id}` +
    `&types%5B%5D=success_seed&types%5B%5D=tree&types%5B%5D=replant` +
    `&orderByField=birth_date&sortDirection=DESC`;

  const rows: Array<Record<string, unknown>> = [];
  for (let page = 1; page <= MAX_FEED_PAGES; page += 1) {
    const res = await bff<{ data?: Array<Record<string, unknown>> }>(
      `/bff/trees/feed?page=${page}&${base}`,
    );
    const batch = res?.data ?? [];
    if (batch.length === 0) break;
    rows.push(...batch);
  }
  return rows;
}

/**
 * Tree-Nation's placeholder text, used when a plant call carried no `message`.
 * It reads like filler on a public feed, so we drop it and let the client show
 * its own neutral line. We deliberately don't substitute a richer sentence: the
 * feed doesn't tell us the species for these, and inventing detail about a real
 * tree is exactly the kind of embellishment this feature exists to avoid.
 * Grants from the app always send a message, so this only affects trees planted
 * outside that path.
 */
const GENERIC_MESSAGES = ['thank you for planting trees at our side!'];

function realMessage(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const text = raw.trim();
  if (!text) return null;
  return GENERIC_MESSAGES.includes(text.toLowerCase()) ? null : text;
}

/**
 * The community forest, cached for 15 minutes. Returns the last good payload if
 * a refresh fails, and null only when we have never had one — the app treats
 * that as "unavailable" rather than showing a wrong number.
 */
export async function fetchCommunityForest(): Promise<CommunityForest | null> {
  if (communityCache && Date.now() - communityCache.at < COMMUNITY_TTL_MS) {
    return communityCache.data;
  }

  const slug = profileSlug();
  const id = ownerId();

  const [profile, feedRows] = await Promise.all([
    bff<{ trees_all?: number; co2_compensated_tons?: number }>(`/bff/profiles/${slug}`),
    fetchAllFeedPages(id),
  ]);
  const feed = { data: feedRows };

  // Never serve a half-answer: without the profile we don't know the true total,
  // and a count that disagrees with the partner's own page is worse than none.
  if (!profile || typeof profile.trees_all !== 'number') {
    return communityCache?.data ?? null;
  }

  const trees: CommunityTree[] = (feed?.data ?? []).map((t) => {
    const token = String(t.hash_token ?? '');
    return {
      id: Number(t.id),
      quantity: Number(t.quantity) || 1,
      message: realMessage(t.message),
      image: typeof t.image === 'string' ? t.image : null,
      planted_at: typeof t.birth_date === 'string' ? t.birth_date : null,
      certificate_url: `${API_BASE}/certificate/${token}`,
      collect_url: `${API_BASE}/collect/${token}`,
    };
  });

  const data: CommunityForest = {
    total_trees: profile.trees_all,
    co2_tons: Number(profile.co2_compensated_tons) || 0,
    profile_url: `${API_BASE}/profile/${slug}`,
    trees,
  };
  communityCache = { data, at: Date.now() };
  return data;
}

/** Test-only. */
export function _resetCommunityCacheForTest(): void {
  communityCache = undefined;
}
