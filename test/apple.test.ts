import { createHash, createSign, generateKeyPairSync, type KeyObject } from 'node:crypto';
import {
  verifyAppleIdentityToken,
  _clearJwksCacheForTest,
  type VerifyOptions,
} from '../src/lib/apple';
import { ApiError } from '../src/lib/errors';

// A stable RSA keypair for the whole suite; the "Apple JWKS" is this key's public
// half, served via a mocked global fetch.
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const KID = 'test-key-1';
const AUD = 'com.verdancy.app';
const RAW_NONCE = 'raw-nonce-value';
const NOW = 1_800_000_000; // fixed "now" (epoch seconds)

function jwkFor(key: KeyObject, kid: string) {
  return { ...key.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' };
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString('base64url');
}

/** Build a signed RS256 identity token with the given claims (+ header kid). */
function signToken(claims: Record<string, unknown>, kid = KID): string {
  const header = b64url(JSON.stringify({ alg: 'RS256', kid }));
  const payload = b64url(JSON.stringify(claims));
  const signer = createSign('RSA-SHA256');
  signer.update(`${header}.${payload}`);
  signer.end();
  const sig = signer.sign(privateKey).toString('base64url');
  return `${header}.${payload}.${sig}`;
}

function validClaims(overrides: Record<string, unknown> = {}) {
  return {
    iss: 'https://appleid.apple.com',
    aud: AUD,
    sub: 'apple-sub-123',
    exp: NOW + 600,
    iat: NOW - 60,
    email: 'user@example.com',
    email_verified: 'true',
    nonce: createHash('sha256').update(RAW_NONCE).digest('hex'),
    ...overrides,
  };
}

const opts: VerifyOptions = { audience: AUD, expectedNonce: RAW_NONCE, now: NOW };

beforeEach(() => {
  _clearJwksCacheForTest();
  global.fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ keys: [jwkFor(publicKey, KID)] }),
  }) as unknown as typeof fetch;
});

async function expectStatus(promise: Promise<unknown>, status: number) {
  await expect(promise).rejects.toMatchObject({ statusCode: status });
  await expect(promise).rejects.toBeInstanceOf(ApiError);
}

describe('verifyAppleIdentityToken', () => {
  test('accepts a well-formed token and returns identity', async () => {
    const identity = await verifyAppleIdentityToken(signToken(validClaims()), opts);
    expect(identity).toEqual({
      sub: 'apple-sub-123',
      email: 'user@example.com',
      emailVerified: true,
      isPrivateEmail: false,
    });
  });

  test('rejects a tampered payload (bad signature)', async () => {
    const token = signToken(validClaims());
    const [h, , s] = token.split('.');
    const forgedPayload = b64url(JSON.stringify(validClaims({ sub: 'attacker' })));
    await expectStatus(verifyAppleIdentityToken(`${h}.${forgedPayload}.${s}`, opts), 401);
  });

  test('rejects a wrong audience', async () => {
    const token = signToken(validClaims({ aud: 'com.someone.else' }));
    await expectStatus(verifyAppleIdentityToken(token, opts), 401);
  });

  test('rejects a wrong issuer', async () => {
    const token = signToken(validClaims({ iss: 'https://evil.example' }));
    await expectStatus(verifyAppleIdentityToken(token, opts), 401);
  });

  test('rejects an expired token (beyond clock skew)', async () => {
    const token = signToken(validClaims({ exp: NOW - 1000 }));
    await expectStatus(verifyAppleIdentityToken(token, opts), 401);
  });

  test('rejects a replayed/mismatched nonce', async () => {
    const token = signToken(validClaims({ nonce: 'someone-elses-nonce' }));
    await expectStatus(verifyAppleIdentityToken(token, opts), 401);
  });

  test('rejects a non-RS256 algorithm', async () => {
    const header = b64url(JSON.stringify({ alg: 'none', kid: KID }));
    const payload = b64url(JSON.stringify(validClaims()));
    await expectStatus(verifyAppleIdentityToken(`${header}.${payload}.`, opts), 401);
  });

  test('rejects an unknown signing key even after a JWKS refetch', async () => {
    // JWKS never contains the token's kid → refetch, still missing → 401.
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ keys: [jwkFor(publicKey, 'a-different-kid')] }),
    }) as unknown as typeof fetch;
    await expectStatus(verifyAppleIdentityToken(signToken(validClaims()), opts), 401);
  });

  test('maps a private-relay email correctly', async () => {
    const token = signToken(
      validClaims({ email: 'abc@privaterelay.appleid.com', is_private_email: true }),
    );
    const identity = await verifyAppleIdentityToken(token, opts);
    expect(identity.isPrivateEmail).toBe(true);
  });
});
