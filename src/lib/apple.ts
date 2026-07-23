import {
  createHash,
  createPublicKey,
  createVerify,
  timingSafeEqual,
  type JsonWebKey,
} from 'node:crypto';
import { ApiError } from './errors';

/**
 * Verify a native Sign in with Apple **identity token** (the JWT that
 * `ASAuthorizationController` returns to the app). We fetch Apple's public JWKS,
 * check the RS256 signature ourselves with Node's crypto (no third-party JWT
 * dependency), then validate issuer, audience, expiry, and the anti-replay nonce.
 *
 * For the NATIVE flow the token's `aud` is the app's **bundle id**
 * (`com.verdancy.app`), not a web Services ID — that's the whole reason this path
 * needs no hosted domain or Services ID.
 */
const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
const JWKS_TTL_MS = 60 * 60 * 1000; // Apple rotates keys slowly; 1h cache is safe.
const CLOCK_SKEW_SEC = 300;

interface AppleJwk {
  kty: string;
  kid: string;
  use?: string;
  alg?: string;
  n: string;
  e: string;
}

let jwksCache: { keys: AppleJwk[]; fetchedAt: number } | undefined;

async function fetchJwks(force = false): Promise<AppleJwk[]> {
  const fresh = jwksCache && Date.now() - jwksCache.fetchedAt < JWKS_TTL_MS;
  if (!force && fresh) return jwksCache!.keys;
  const res = await fetch(APPLE_JWKS_URL);
  if (!res.ok) throw new Error(`Apple JWKS fetch failed: ${res.status}`);
  const body = (await res.json()) as { keys?: AppleJwk[] };
  if (!Array.isArray(body.keys)) throw new Error('Apple JWKS response malformed');
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

/** Find the signing key for `kid`, refetching once in case Apple rotated keys. */
async function findKey(kid: string): Promise<AppleJwk> {
  let key = (await fetchJwks()).find((k) => k.kid === kid);
  if (!key) key = (await fetchJwks(true)).find((k) => k.kid === kid);
  if (!key) throw new ApiError(401, 'Unknown token signing key');
  return key;
}

function b64url(s: string): Buffer {
  return Buffer.from(s, 'base64url');
}

/** Constant-time string compare that first rejects length mismatch. */
function constantTimeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

export interface AppleIdentity {
  /** Apple's stable per-app user identifier (the token `sub`). */
  sub: string;
  email?: string;
  emailVerified: boolean;
  isPrivateEmail: boolean;
}

export interface VerifyOptions {
  /** Accepted `aud` value(s) — the app bundle id for native sign-in. */
  audience: string | string[];
  /**
   * The RAW nonce the app generated for this sign-in. The token's `nonce` claim
   * must equal the SHA-256 hex of it (the app sends SHA-256 to Apple). Required —
   * omitting it would remove replay protection.
   */
  expectedNonce: string;
  /** Override "now" (epoch seconds) for tests. */
  now?: number;
}

export async function verifyAppleIdentityToken(
  idToken: string,
  opts: VerifyOptions,
): Promise<AppleIdentity> {
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

  // Signature over the exact `header.payload` bytes with Apple's public key.
  const jwk = await findKey(header.kid);
  const pubKey = createPublicKey({ key: jwk as unknown as JsonWebKey, format: 'jwk' });
  const verifier = createVerify('RSA-SHA256');
  verifier.update(`${headerB64}.${payloadB64}`);
  verifier.end();
  if (!verifier.verify(pubKey, b64url(sigB64))) {
    throw new ApiError(401, 'Invalid token signature');
  }

  // Claims.
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  if (payload.iss !== APPLE_ISSUER) throw new ApiError(401, 'Bad token issuer');

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

  // Apple sends email_verified / is_private_email as either boolean or "true"/"false".
  const truthy = (v: unknown) => v === true || v === 'true';
  return {
    sub,
    email: typeof payload.email === 'string' ? payload.email : undefined,
    emailVerified: truthy(payload.email_verified),
    isPrivateEmail: truthy(payload.is_private_email),
  };
}

/** Test-only: drop the cached JWKS so a test's mocked fetch is used. */
export function _clearJwksCacheForTest(): void {
  jwksCache = undefined;
}
