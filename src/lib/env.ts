/** Small env/time helpers shared by the handlers. */

export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

export function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  const n = raw ? Number.parseInt(raw, 10) : NaN;
  return Number.isFinite(n) ? n : fallback;
}

/** UTC calendar day, `YYYY-MM-DD` — the daily-quota item key suffix. */
export function todayUtc(date = new Date()): string {
  return date.toISOString().slice(0, 10);
}

export function nowIso(date = new Date()): string {
  return date.toISOString();
}

/** Epoch-seconds TTL ~48h out, for the daily-quota item's `expires_at`. */
export function quotaTtlEpoch(date = new Date()): number {
  return Math.floor(date.getTime() / 1000) + 48 * 3600;
}
