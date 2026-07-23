import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';

/**
 * Tiny cached Secrets Manager reader shared by handlers that authenticate with a
 * Secrets-Manager value (hard invariant #10: secrets only from Secrets Manager,
 * never hardcoded, never logged). The cache lives for the container's lifetime,
 * so a warm Lambda reads the secret once.
 */
const sm = new SecretsManagerClient({});
const cache = new Map<string, string>();

export async function getSecretString(secretId: string): Promise<string> {
  const hit = cache.get(secretId);
  if (hit !== undefined) return hit;
  const res = await sm.send(new GetSecretValueCommand({ SecretId: secretId }));
  if (!res.SecretString) throw new Error('Secret has no SecretString value');
  cache.set(secretId, res.SecretString);
  return res.SecretString;
}

/** Test-only: drop the in-memory cache between tests. */
export function _clearSecretCacheForTest(): void {
  cache.clear();
}
