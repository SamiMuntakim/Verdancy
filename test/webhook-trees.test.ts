jest.mock('../src/lib/planting', () => ({ grantTrees: jest.fn() }));

import { mockClient } from 'aws-sdk-client-mock';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { DynamoDBDocumentClient, UpdateCommand, GetCommand } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';
import { handler, _clearSecretCacheForTest } from '../src/handlers/webhook';
import { grantTrees } from '../src/lib/planting';

const smMock = mockClient(SecretsManagerClient);
const ddbMock = mockClient(DynamoDBDocumentClient);
const mockGrant = grantTrees as jest.Mock;

const SECRET = 'webhook-shared-secret';

function call(body: unknown) {
  const event = {
    headers: { authorization: SECRET },
    body: JSON.stringify(body),
    isBase64Encoded: false,
    requestContext: { http: { method: 'POST', path: '/webhooks/revenuecat' } },
  } as unknown as APIGatewayProxyEventV2;
  return handler(event) as Promise<APIGatewayProxyStructuredResultV2>;
}

beforeAll(() => {
  process.env.TABLE_NAME = 'VerdancyData';
  process.env.REVENUECAT_WEBHOOK_SECRET_ARN = 'arn:aws:secretsmanager:us-west-1:123:secret:wh';
});

beforeEach(() => {
  smMock.reset();
  ddbMock.reset();
  mockGrant.mockReset();
  _clearSecretCacheForTest();
  smMock.on(GetSecretValueCommand).resolves({ SecretString: SECRET });
  ddbMock.on(UpdateCommand).resolves({});
  ddbMock.on(GetCommand).resolves({ Item: {} }); // no referral by default
  mockGrant.mockResolvedValue(true);
});

const annual = (over: Record<string, unknown> = {}) => ({
  event: {
    id: 'evt-1',
    type: 'INITIAL_PURCHASE',
    app_user_id: 'sub-1',
    product_id: 'verdancy_annual',
    ...over,
  },
});

describe('annual vs monthly tree grants', () => {
  test('annual initial purchase grants 10 trees', async () => {
    await call(annual());
    expect(mockGrant).toHaveBeenCalledWith(
      expect.objectContaining({ sub: 'sub-1', quantity: 10, reason: 'annual_subscription' }),
    );
  });

  test('annual RENEWAL grants another 10 trees', async () => {
    await call(annual({ type: 'RENEWAL', id: 'evt-2' }));
    expect(mockGrant).toHaveBeenCalledWith(expect.objectContaining({ quantity: 10 }));
  });

  test('MONTHLY grants no trees', async () => {
    await call(annual({ product_id: 'verdancy_monthly' }));
    expect(mockGrant).not.toHaveBeenCalled();
  });

  test('the milestone id is unique per event, so retries cannot double-plant', async () => {
    await call(annual());
    const first = mockGrant.mock.calls[0][0].milestoneId;
    mockGrant.mockClear();
    await call(annual()); // same event id redelivered
    expect(mockGrant.mock.calls[0][0].milestoneId).toBe(first);
    // …and a genuine renewal is a DIFFERENT event id → a different milestone.
    mockGrant.mockClear();
    await call(annual({ type: 'RENEWAL', id: 'evt-99' }));
    expect(mockGrant.mock.calls[0][0].milestoneId).not.toBe(first);
  });

  test('an expiration event grants nothing', async () => {
    await call(annual({ type: 'EXPIRATION' }));
    expect(mockGrant).not.toHaveBeenCalled();
  });

  // StoreKit's sandbox renews an annual sub roughly hourly, up to 6 times — each
  // a distinct event that would otherwise claim its own 10-tree grant.
  test('a SANDBOX purchase grants the entitlement but plants NOTHING', async () => {
    const res = await call(annual({ environment: 'SANDBOX' }));
    expect(res.statusCode).toBe(200);
    expect(ddbMock.commandCalls(UpdateCommand).length).toBeGreaterThan(0); // entitlement written
    expect(mockGrant).not.toHaveBeenCalled(); // but no money spent
  });

  test('a SANDBOX renewal plants nothing either', async () => {
    await call(annual({ type: 'RENEWAL', id: 'evt-sandbox-2', environment: 'SANDBOX' }));
    expect(mockGrant).not.toHaveBeenCalled();
  });

  test('PRODUCTION still plants', async () => {
    await call(annual({ environment: 'PRODUCTION' }));
    expect(mockGrant).toHaveBeenCalledWith(expect.objectContaining({ quantity: 10 }));
  });

  test('a planting failure still returns 200 (entitlement ack is not blocked)', async () => {
    mockGrant.mockRejectedValue(new Error('tree-nation down'));
    const res = await call(annual());
    expect(res.statusCode).toBe(200);
  });
});

describe('referral trees', () => {
  test('a SANDBOX referral is credited but plants no trees', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { referred_by: 'inviter-9' } });
    await call(annual({ environment: 'SANDBOX' }));
    expect(mockGrant).not.toHaveBeenCalled();
  });

  test("a referred user's first purchase plants one tree for each side", async () => {
    ddbMock.on(GetCommand).resolves({ Item: { referred_by: 'inviter-9' } });
    await call(annual({ product_id: 'verdancy_monthly' })); // monthly: referral only, no annual grant
    const reasons = mockGrant.mock.calls.map((c) => c[0].reason);
    expect(reasons).toContain('referral_joined');
    expect(reasons).toContain('referral_invited');
    const subs = mockGrant.mock.calls.map((c) => c[0].sub);
    expect(subs).toEqual(expect.arrayContaining(['sub-1', 'inviter-9']));
    expect(mockGrant.mock.calls.every((c) => c[0].quantity === 1)).toBe(true);
  });
});
