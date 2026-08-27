import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { floatEnv, intEnv } from './env';

/**
 * Tree-Nation planting client (`POST /api/plant`). Spends real tree credits.
 *
 * **Species choice is a request, not a guarantee.** Verified against the live
 * API 2026-08: a plant pinning `species_id` 1342 came back as 3658, because
 * 1342 had gone to `stock: 0` and Tree-Nation substituted an in-stock species.
 * So we ask for the cheapest species that is actually IN STOCK right now,
 * recomputed per plant, and we still bound the worst case in case the request
 * is overridden anyway.
 *
 * Layers, all fail-safe (uncertainty → don't spend):
 *  1. Ask for the cheapest in-stock species (keeps the usual cost at the floor).
 *  2. Refuse to plant unless the DEAREST in-stock species is within
 *     `MAX_TREE_PRICE_EUR` — the true bound on what a tree can cost us.
 *  3. Log loudly if what came back isn't what we asked for, so paying above the
 *     floor is visible immediately rather than at invoice time.
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

/** Hard per-tree price ceiling in the account's currency (default €0.50). */
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
 * Fail-safe price guard: true only if EVERY species Tree-Nation could pick for
 * us is at or under the ceiling. We ask for the cheapest, but the ceiling is
 * checked against the worst case, because the request may be overridden. Any
 * uncertainty — lookup failed, a malformed entry, nothing in stock, or an
 * in-stock species above the cap — returns false and the caller must not plant.
 */
export async function withinBudget(): Promise<boolean> {
  const pricing = await fetchProjectPricing();
  if (!pricing) return false; // can't verify → don't spend
  return pricing.worstCase <= maxTreePrice();
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
  if (pricing.worstCase > maxTreePrice()) {
    console.error(
      `Tree-Nation: in-stock species at ${pricing.worstCase} exceeds the ${maxTreePrice()} cap — not planting`,
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
  }
  return { trees, payment_id: data.payment_id };
}

/** Test-only: reset caches between unit tests. */
export function _resetTreeNationCachesForTest(): void {
  cachedToken = undefined;
  projectCache = undefined;
}
