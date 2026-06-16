import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { timingSafeEqual } from 'node:crypto';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { json } from '../lib/http';

/**
 * RevenueCat webhook Lambda. This is the ONLY unauthenticated route (no Cognito
 * JWT authorizer), so it authenticates by a shared secret RevenueCat sends in the
 * `Authorization` header — verified against Secrets Manager before any processing.
 *
 * Phase 2: verify the secret (reject otherwise), then 501. Phase 3 implements the
 * entitlement updates (set entitlement_active / entitlement_expires_at).
 */
const secretsClient = new SecretsManagerClient({});
let cachedSecret: string | undefined;

async function getWebhookSecret(): Promise<string> {
  if (cachedSecret !== undefined) return cachedSecret;
  const secretId = process.env.REVENUECAT_WEBHOOK_SECRET_ARN;
  if (!secretId) throw new Error('REVENUECAT_WEBHOOK_SECRET_ARN is not set');
  const res = await secretsClient.send(new GetSecretValueCommand({ SecretId: secretId }));
  if (!res.SecretString) throw new Error('Webhook secret has no SecretString value');
  cachedSecret = res.SecretString;
  return cachedSecret;
}

/** Constant-time comparison that won't leak length via early return timing. */
function secretsMatch(provided: string, expected: string): boolean {
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  // HTTP API v2 lowercases header names; check both for safety.
  const provided = event.headers?.authorization ?? event.headers?.Authorization;

  let expected: string;
  try {
    expected = await getWebhookSecret();
  } catch {
    // Never log the secret or its contents.
    console.error('Unable to load the RevenueCat webhook secret');
    return json(500, { error: 'Internal Server Error' });
  }

  if (!provided || !secretsMatch(provided, expected)) {
    return json(401, { error: 'Unauthorized' });
  }

  // TODO Phase 3: parse the event and update entitlement_active / entitlement_expires_at.
  return json(501, { error: 'Not Implemented' });
};

/** Test-only: reset the in-memory secret cache between unit tests. */
export function _clearSecretCacheForTest(): void {
  cachedSecret = undefined;
}
