import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { timingSafeEqual } from 'node:crypto';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { json, parseJsonBody } from '../lib/http';
import { setEntitlement, getMetadata, markReferralCredited, recordMilestone } from '../lib/dynamo';

/**
 * RevenueCat webhook Lambda. This is the ONLY unauthenticated route (no Cognito
 * JWT authorizer), so it authenticates by a shared secret RevenueCat sends in the
 * `Authorization` header — verified against Secrets Manager before any processing
 * (hard invariant #9: entitlement truth is server-side). RevenueCat's
 * `app_user_id` is the Cognito `sub`, so events map straight to a user.
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

/** Constant-time comparison that won't leak length via early-return timing. */
function secretsMatch(provided: string, expected: string): boolean {
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

// Per PRD 4.6: these grant the entitlement; these revoke it. Other event types
// (e.g. TEST, TRANSFER) are acknowledged with 200 but change nothing.
const ACTIVATE = new Set(['INITIAL_PURCHASE', 'RENEWAL', 'PRODUCT_CHANGE', 'UNCANCELLATION']);
const DEACTIVATE = new Set(['EXPIRATION', 'CANCELLATION', 'BILLING_ISSUE']);

interface RevenueCatEvent {
  type?: string;
  app_user_id?: string;
  expiration_at_ms?: number;
}

function toEpochSeconds(ms: unknown): number | null {
  return typeof ms === 'number' && Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

/**
 * Referral credit (iOS-PRD §10): when an invited friend's FIRST purchase lands,
 * plant a tree for both. `markReferralCredited` is an atomic one-time claim, so
 * webhook retries / duplicate events can't double-credit; the milestone writes
 * themselves are the usual idempotent conditional ADDs.
 */
async function creditReferralIfAny(sub: string): Promise<void> {
  const meta = await getMetadata(sub);
  const inviter = meta?.referred_by;
  if (!inviter || meta?.referral_credited) return;
  if (!(await markReferralCredited(sub))) return; // someone else claimed it

  // One tree for the new subscriber…
  await recordMilestone(sub, 'referral_joined');
  // …and one for the inviter, unique per referred friend.
  await recordMilestone(inviter, `referral_${sub.slice(0, 12)}`);
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  // HTTP API v2 lowercases header names; check both for safety.
  const provided = event.headers?.authorization ?? event.headers?.Authorization;

  let expected: string;
  try {
    expected = await getWebhookSecret();
  } catch {
    console.error('Unable to load the RevenueCat webhook secret');
    return json(500, { error: 'Internal Server Error' });
  }

  if (!provided || !secretsMatch(provided, expected)) {
    return json(401, { error: 'Unauthorized' });
  }

  let rcEvent: RevenueCatEvent;
  try {
    const body = parseJsonBody<{ event?: RevenueCatEvent }>(event);
    rcEvent = body.event ?? {};
  } catch {
    return json(400, { error: 'Invalid JSON body' });
  }

  const { type, app_user_id: appUserId } = rcEvent;
  if (!type || !appUserId) {
    return json(400, { error: 'Missing event type or app_user_id' });
  }

  try {
    if (ACTIVATE.has(type)) {
      await setEntitlement(appUserId, true, toEpochSeconds(rcEvent.expiration_at_ms));
      if (type === 'INITIAL_PURCHASE') {
        // Best-effort: a referral-credit failure must not fail the entitlement ack.
        await creditReferralIfAny(appUserId).catch(() => {
          console.error('Referral credit failed');
        });
      }
    } else if (DEACTIVATE.has(type)) {
      await setEntitlement(appUserId, false, toEpochSeconds(rcEvent.expiration_at_ms));
    }
    // Unhandled types are acknowledged without a write.
    return json(200, { ok: true });
  } catch {
    console.error('Failed to apply entitlement update');
    return json(500, { error: 'Internal Server Error' });
  }
};

/** Test-only: reset the in-memory secret cache between unit tests. */
export function _clearSecretCacheForTest(): void {
  cachedSecret = undefined;
}
