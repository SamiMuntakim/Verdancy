import {
  createHash,
  createPublicKey,
  createVerify,
  timingSafeEqual,
  type JsonWebKey,
} from 'node:crypto';
import { ApiError } from './errors';

/**
 * Verify a Google **ID token** (the JWT the app gets from the Google OAuth flow).
 * Same shape as the Apple verifier: fetch Google's public JWKS, check the RS256
 * signature with Node crypto (no third-party JWT dependency), then validate
 * issuer, audience, expiry, and the anti-replay nonce.
 */
const GOOGLE_ISSUERS = new Set(['https://accounts.google.com', 'accounts.google.com']);
const GOOGLE_JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
const JWKS_TTL_MS = 60 * 60 * 1000;
const CLOCK_SKEW_SEC = 300;

interface GoogleJwk {
  kty: string;
  kid: string;
  use?: string;
  alg?: string;
  n: string;
  e: string;
}

let jwksCache: { keys: GoogleJwk[]; fetchedAt: number } | undefined;

async function fetchJwks(force = false): Promise<GoogleJwk[]> {
  const fresh = jwksCache && Date.now() - jwksCache.fetchedAt < JWKS_TTL_MS;
  if (!force && fresh) return jwksCache!.keys;
  const res = await fetch(GOOGLE_JWKS_URL);
  if (!res.ok) throw new Error(`Google JWKS fetch failed: ${res.status}`);
  const body = (await res.json()) as { keys?: GoogleJwk[] };
  if (!Array.isArray(body.keys)) throw new Error('Google JWKS response malformed');
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

async function findKey(kid: string): Promise<GoogleJwk> {
  let key = (await fetchJwks()).find((k) => k.kid === kid);
  if (!key) key = (await fetchJwks(true)).find((k) => k.kid === kid);
  if (!key) throw new ApiError(401, 'Unknown token signing key');
  return key;
}

function b64url(s: string): Buffer {
  return Buffer.from(s, 'base64url');
}

function constantTimeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

export interface GoogleIdentity {
  sub: string;
  email?: string;
  emailVerified: boolean;
}

export interface VerifyGoogleOptions {
  /** Accepted `aud` — the Google OAuth client id. */
  audience: string | string[];
  /** The RAW nonce the app generated; the token's `nonce` must equal it. */
  expectedNonce: string;
  now?: number;
}

export async function verifyGoogleIdToken(
  idToken: string,
  opts: VerifyGoogleOptions,
): Promise<GoogleIdentity> {
  const parts = idToken.split('.');
  if (parts.length !== 3) throw new ApiError(401, 'Malformed identity token');
  const [headerB64, payloadB64, sigB64] = parts;

  let header: { alg?: string; kid?: string };
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(b64url(headerB64).toString('utf8'));
    payload = JSON.parse(b64url(payloadB64).toString('utf8'));
  } catch {
    throw new ApiError(401, 'Malformed identity token');
  }
  if (header.alg !== 'RS256' || !header.kid) {
    throw new ApiError(401, 'Unsupported token algorithm');
  }

  const jwk = await findKey(header.kid);
  const pubKey = createPublicKey({ key: jwk as unknown as JsonWebKey, format: 'jwk' });
  const verifier = createVerify('RSA-SHA256');
  verifier.update(`${headerB64}.${payloadB64}`);
  verifier.end();
  if (!verifier.verify(pubKey, b64url(sigB64))) {
    throw new ApiError(401, 'Invalid token signature');
  }

  const now = opts.now ?? Math.floor(Date.now() / 1000);
  if (typeof payload.iss !== 'string' || !GOOGLE_ISSUERS.has(payload.iss)) {
    throw new ApiError(401, 'Bad token issuer');
  }
  const audiences = Array.isArray(opts.audience) ? opts.audience : [opts.audience];
  if (typeof payload.aud !== 'string' || !audiences.includes(payload.aud)) {
    throw new ApiError(401, 'Bad token audience');
  }
  if (typeof payload.exp !== 'number' || payload.exp + CLOCK_SKEW_SEC < now) {
    throw new ApiError(401, 'Token expired');
  }
  if (typeof payload.iat === 'number' && payload.iat - CLOCK_SKEW_SEC > now) {
    throw new ApiError(401, 'Token not yet valid');
  }

  const expectedNonce = createHash('sha256').update(opts.expectedNonce).digest('hex');
  const tokenNonce = typeof payload.nonce === 'string' ? payload.nonce : '';
  if (!constantTimeEqual(tokenNonce, expectedNonce)) {
    throw new ApiError(401, 'Nonce mismatch');
  }

  const sub = payload.sub;
  if (typeof sub !== 'string' || sub.length === 0) throw new ApiError(401, 'Missing subject');

  const truthy = (v: unknown) => v === true || v === 'true';
  return {
    sub,
    email: typeof payload.email === 'string' ? payload.email : undefined,
    emailVerified: truthy(payload.email_verified),
  };
}

/** Test-only: drop the cached JWKS so a test's mocked fetch is used. */
export function _clearJwksCacheForTest(): void {
  jwksCache = undefined;
}
