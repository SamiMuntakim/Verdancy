import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { floatEnv, intEnv } from './env';

/**
 * Tree-Nation planting client (`POST /api/plant`). Spends real tree credits.
 *
 * **We do not choose the species.** Verified against the live API 2026-08:
 * passing `species_id` is silently IGNORED — a request pinning 1342 planted
 * 3658 instead, because 1342 had no stock. Tree-Nation picks from the account's
 * project, so any guard that prices one chosen species is checking something
 * that won't be planted.
 *
 * So the guard bounds the WORST CASE instead: the most expensive in-stock
 * species in the configured project must be at or under `MAX_TREE_PRICE_EUR`.
 * Whatever Tree-Nation then picks is guaranteed to be within budget. If they
 * ever stock something pricier in that project, planting stops until a human
 * reviews it, rather than quietly costing more.
 *
 * Layers, all fail-safe (uncertainty → don't spend):
 *  1. `withinBudget()` — the project-wide worst-case price check above.
 *  2. The caller reserves a global daily budget (circuit breaker) first.
 *  3. The caller claims an atomic milestone before spending (exactly-once).
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
  price: number;
  stock: number;
}

// Cache the project lookup so we don't hit the species endpoint on every plant,
// but refresh often enough to notice a price change or new stock.
let projectCache: { id: number; maxPrice: number | null; at: number } | undefined;
const PROJECT_TTL_MS = 60 * 60 * 1000; // 1h

/**
 * The highest price among IN-STOCK species in the project — i.e. the most a
 * single tree can cost us. Returns null if it can't be determined (network
 * failure, malformed payload, or nothing in stock at all).
 */
async function fetchWorstCasePrice(id: number): Promise<number | null> {
  if (projectCache && projectCache.id === id && Date.now() - projectCache.at < PROJECT_TTL_MS) {
    return projectCache.maxPrice;
  }
  try {
    const res = await fetch(`${API_BASE}/api/projects/${id}/species`);
    if (!res.ok) return null;
    const data = (await res.json()) as unknown;
    if (!Array.isArray(data) || data.length === 0) return null;

    let worst: number | null = null;
    for (const raw of data as Species[]) {
      const price = Number(raw?.price);
      const stock = Number(raw?.stock);
      // A malformed entry could hide a real price — refuse rather than guess.
      if (!Number.isFinite(price) || !Number.isFinite(stock)) return null;
      if (stock > 0) worst = worst === null ? price : Math.max(worst, price);
    }
    projectCache = { id, maxPrice: worst, at: Date.now() };
    return worst;
  } catch {
    return null;
  }
}

/**
 * Fail-safe price guard: true only if EVERY species Tree-Nation could pick for
 * us is at or under the ceiling. Any uncertainty — lookup failed, a malformed
 * entry, nothing in stock, or an in-stock species above the cap — returns false
 * and the caller must not plant.
 */
export async function withinBudget(): Promise<boolean> {
  const worst = await fetchWorstCasePrice(projectId());
  if (worst === null) return false; // can't verify → don't spend
  return worst <= maxTreePrice();
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
  if (!(await withinBudget())) {
    console.error('Tree-Nation: price guard blocked planting (price/stock/verify failure)');
    return null;
  }

  const token = await getApiToken();
  // No `species_id`: the API ignores it (verified 2026-08) and picks from the
  // account's project. `withinBudget()` above is what bounds the cost.
  const body: Record<string, unknown> = {
    recipients: [{ internal_id: opts.internalId }],
    quantity: opts.quantity,
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
  return { trees: data.trees ?? [], payment_id: data.payment_id };
}

/** Test-only: reset caches between unit tests. */
export function _resetTreeNationCachesForTest(): void {
  cachedToken = undefined;
  projectCache = undefined;
}
