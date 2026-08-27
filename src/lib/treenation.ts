import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { floatEnv, intEnv } from './env';

/**
 * Tree-Nation planting client (`POST /api/plant`). Spends real tree credits, so
 * every call is guarded by THREE independent, fail-safe layers (see the callers
 * for the other two):
 *
 *  1. We pin a specific cheap `species_id` — never "select by price".
 *  2. `withinBudget()` re-checks the pinned species' LIVE price + stock against
 *     `MAX_TREE_PRICE_EUR` before every plant. Above the cap, out of stock, or if
 *     the check itself can't be trusted → we DO NOT plant. Failing means not
 *     spending, never over-spending.
 *  3. The caller reserves a global daily budget (circuit breaker) first.
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

/** Species id we plant (default 1342 = Albizia gummifera, €0.35, deep stock). */
function speciesId(): number {
  return intEnv('TREENATION_SPECIES_ID', 1342);
}

/** Hard per-tree price ceiling in the account's currency (default €0.35). */
function maxTreePrice(): number {
  return floatEnv('MAX_TREE_PRICE_EUR', 0.35);
}

interface SpeciesInfo {
  price: number;
  stock: number;
}

// Cache the price/stock lookup so we don't hit the species endpoint on every
// plant, but refresh often enough to notice a price rise or a stock-out.
let speciesCache: { id: number; info: SpeciesInfo; at: number } | undefined;
const SPECIES_TTL_MS = 60 * 60 * 1000; // 1h

async function fetchSpecies(id: number): Promise<SpeciesInfo | null> {
  if (speciesCache && speciesCache.id === id && Date.now() - speciesCache.at < SPECIES_TTL_MS) {
    return speciesCache.info;
  }
  try {
    const res = await fetch(`${API_BASE}/api/species/${id}`);
    if (!res.ok) return null;
    const data = (await res.json()) as { price?: unknown; stock?: unknown };
    const price = typeof data.price === 'number' ? data.price : Number(data.price);
    const stock = typeof data.stock === 'number' ? data.stock : Number(data.stock);
    if (!Number.isFinite(price) || !Number.isFinite(stock)) return null;
    const info: SpeciesInfo = { price, stock };
    speciesCache = { id, info, at: Date.now() };
    return info;
  } catch {
    return null;
  }
}

/**
 * Fail-safe price guard: true only if we can CONFIRM the pinned species is at or
 * under the cap and in stock. Any uncertainty (lookup failed, price too high,
 * no stock) returns false → the caller must not plant.
 */
export async function withinBudget(): Promise<boolean> {
  const info = await fetchSpecies(speciesId());
  if (!info) return false; // can't verify → don't spend
  return info.price <= maxTreePrice() && info.stock > 0;
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
  const body: Record<string, unknown> = {
    recipients: [{ internal_id: opts.internalId }],
    quantity: opts.quantity,
    species_id: speciesId(),
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
  speciesCache = undefined;
}
