import { createHash, createSign, generateKeyPairSync, type KeyObject } from 'node:crypto';
import {
  verifyGoogleIdToken,
  _clearJwksCacheForTest,
  type VerifyGoogleOptions,
} from '../src/lib/google';
import { ApiError } from '../src/lib/errors';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const KID = 'g-key-1';
const AUD = '463079233513-abc.apps.googleusercontent.com';
const RAW_NONCE = 'raw-nonce-value';
const NOW = 1_800_000_000;

function jwkFor(key: KeyObject, kid: string) {
  return { ...key.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' };
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString('base64url');
}

function signToken(claims: Record<string, unknown>, kid = KID): string {
  const header = b64url(JSON.stringify({ alg: 'RS256', kid }));
  const payload = b64url(JSON.stringify(claims));
  const signer = createSign('RSA-SHA256');
  signer.update(`${header}.${payload}`);
  signer.end();
  return `${header}.${payload}.${signer.sign(privateKey).toString('base64url')}`;
}

function validClaims(overrides: Record<string, unknown> = {}) {
  return {
    iss: 'https://accounts.google.com',
    aud: AUD,
    sub: 'google-sub-123',
    exp: NOW + 600,
    iat: NOW - 60,
    email: 'user@gmail.com',
    email_verified: true,
    nonce: createHash('sha256').update(RAW_NONCE).digest('hex'),
    ...overrides,
  };
}

const opts: VerifyGoogleOptions = { audience: AUD, expectedNonce: RAW_NONCE, now: NOW };

beforeEach(() => {
  _clearJwksCacheForTest();
  global.fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ keys: [jwkFor(publicKey, KID)] }),
  }) as unknown as typeof fetch;
});

async function expect401(promise: Promise<unknown>) {
  await expect(promise).rejects.toMatchObject({ statusCode: 401 });
  await expect(promise).rejects.toBeInstanceOf(ApiError);
}

describe('verifyGoogleIdToken', () => {
  test('accepts a well-formed token and returns identity', async () => {
    const identity = await verifyGoogleIdToken(signToken(validClaims()), opts);
    expect(identity).toEqual({
      sub: 'google-sub-123',
      email: 'user@gmail.com',
      emailVerified: true,
    });
  });

  test('accepts the alternate bare issuer accounts.google.com', async () => {
    const identity = await verifyGoogleIdToken(
      signToken(validClaims({ iss: 'accounts.google.com' })),
      opts,
    );
    expect(identity.sub).toBe('google-sub-123');
  });

  test('rejects a tampered payload (bad signature)', async () => {
    const token = signToken(validClaims());
    const [h, , s] = token.split('.');
    const forged = b64url(JSON.stringify(validClaims({ sub: 'attacker' })));
    await expect401(verifyGoogleIdToken(`${h}.${forged}.${s}`, opts));
  });

  test('rejects a wrong audience', async () => {
    await expect401(
      verifyGoogleIdToken(
        signToken(validClaims({ aud: 'other.apps.googleusercontent.com' })),
        opts,
      ),
    );
  });

  test('rejects a wrong issuer', async () => {
    await expect401(
      verifyGoogleIdToken(signToken(validClaims({ iss: 'https://evil.example' })), opts),
    );
  });

  test('rejects an expired token', async () => {
    await expect401(verifyGoogleIdToken(signToken(validClaims({ exp: NOW - 1000 })), opts));
  });

  test('rejects a replayed/mismatched nonce', async () => {
    await expect401(verifyGoogleIdToken(signToken(validClaims({ nonce: 'someone-elses' })), opts));
  });
});
