import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { timingSafeEqual } from 'node:crypto';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { json, parseJsonBody } from '../lib/http';
import { setEntitlement, getMetadata, markReferralCredited } from '../lib/dynamo';
import { grantTrees } from '../lib/planting';

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
  id?: string;
  type?: string;
  app_user_id?: string;
  product_id?: string;
  /** RevenueCat sends 'SANDBOX' for test purchases, 'PRODUCTION' for real ones. */
  environment?: string;
  /** 'TRIAL' | 'INTRO' | 'PROMOTIONAL' | 'NORMAL' — only NORMAL means money moved. */
  period_type?: string;
  expiration_at_ms?: number;
}

/**
 * Tree grants (real Tree-Nation plantings, funded by us):
 *   - ANNUAL subscription (initial purchase or renewal) → 10 trees, per period.
 *   - MONTHLY subscription → 1 tree, per period.
 *   - A referred friend's first purchase → 1 tree for them, 1 for the inviter.
 */
const ANNUAL_PRODUCT_ID = process.env.ANNUAL_PRODUCT_ID ?? 'verdancy_annual';
const MONTHLY_PRODUCT_ID = process.env.MONTHLY_PRODUCT_ID ?? 'verdancy_monthly';
const ANNUAL_TREES = 10;
const MONTHLY_TREES = 1;

/** Trees funded by one subscription period, or 0 for anything we don't sell. */
function treesForProduct(productId: string | undefined): number {
  if (productId === ANNUAL_PRODUCT_ID) return ANNUAL_TREES;
  if (productId === MONTHLY_PRODUCT_ID) return MONTHLY_TREES;
  return 0;
}

/**
 * Only real money plants real trees. Sandbox purchases still grant the
 * entitlement (so TestFlight/dev builds behave like the real app), but they must
 * never spend tree credits: StoreKit's sandbox renews an annual subscription
 * roughly hourly, up to six times, and each renewal is a distinct event that
 * would otherwise claim its own 10-tree grant.
 */
function isSandbox(event: RevenueCatEvent): boolean {
  return (event.environment ?? '').toUpperCase() === 'SANDBOX';
}

/**
 * Only a PAID period funds trees.
 *
 * A free trial arrives as INITIAL_PURCHASE with `period_type: "TRIAL"`, so
 * without this a 7-day trial planted its full grant up front — real money spent
 * before any arrived, and refundable by simply cancelling on day six. When the
 * trial converts, RevenueCat sends a RENEWAL with `period_type: "NORMAL"`, and
 * the trees are funded then: the tree follows the payment, not the signup.
 *
 * Unknown or missing period types are treated as unpaid. That errs toward not
 * spending, and the log line makes the case visible rather than silent.
 */
function isPaidPeriod(event: RevenueCatEvent): boolean {
  const period = (event.period_type ?? '').toUpperCase();
  if (period === 'NORMAL') return true;
  console.log(`No trees: period_type is "${event.period_type ?? 'missing'}", not a paid period`);
  return false;
}

/**
 * Plant a subscription period's trees: 10 for a year, 1 for a month. The
 * milestone id is unique per RevenueCat event, so a retried or duplicated
 * delivery of the SAME event can't double-plant, while each real renewal is a
 * new event and funds a fresh batch.
 */
async function grantSubscriptionTrees(event: RevenueCatEvent, sub: string): Promise<void> {
  const quantity = treesForProduct(event.product_id);
  if (quantity === 0) return; // not a product that funds trees
  if (isSandbox(event)) {
    console.log('Sandbox purchase — entitlement granted, no trees planted');
    return;
  }
  if (!isPaidPeriod(event)) return; // a trial funds nothing until it converts
  const periodKey = event.id ?? String(event.expiration_at_ms ?? '');
  if (!periodKey) return;
  await grantTrees({
    sub,
    milestoneId: `sub_${periodKey}`,
    quantity,
    reason: quantity === ANNUAL_TREES ? 'annual_subscription' : 'monthly_subscription',
    message: 'Thank you for growing with Verdancy 🌱',
  });
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
async function creditReferralIfAny(sub: string, sandbox: boolean): Promise<void> {
  const meta = await getMetadata(sub);
  const inviter = meta?.referred_by;
  if (!inviter || meta?.referral_credited) return;
  if (!(await markReferralCredited(sub))) return; // someone else claimed it
  if (sandbox) {
    console.log('Sandbox purchase — referral credited, no trees planted');
    return;
  }

  // One real tree for the new subscriber…
  await grantTrees({
    sub,
    milestoneId: 'referral_joined',
    quantity: 1,
    reason: 'referral_joined',
    message: 'Welcome to Verdancy 🌱',
  });
  // …and one for the inviter, unique per referred friend.
  await grantTrees({
    sub: inviter,
    milestoneId: `referral_${sub.slice(0, 12)}`,
    quantity: 1,
    reason: 'referral_invited',
    message: 'Thanks for growing the forest 🌱',
  });
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
      if (type === 'INITIAL_PURCHASE' || type === 'RENEWAL') {
        // Best-effort: a planting failure must not fail the entitlement ack.
        await grantSubscriptionTrees(rcEvent, appUserId).catch(() => {
          console.error('Subscription tree grant failed');
        });
        // Referrals wait for money too, so this runs on the converting RENEWAL
        // as well as a straight purchase. `markReferralCredited` is a one-time
        // claim, so repeating it across renewals credits exactly once.
        if (isPaidPeriod(rcEvent)) {
          await creditReferralIfAny(appUserId, isSandbox(rcEvent)).catch(() => {
            console.error('Referral credit failed');
          });
        }
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
