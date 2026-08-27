import { mockClient } from 'aws-sdk-client-mock';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { DynamoDBDocumentClient, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { withinBudget, plantTrees, _resetTreeNationCachesForTest } from '../src/lib/treenation';
import { reserveGlobalTreeBudget } from '../src/lib/dynamo';

const smMock = mockClient(SecretsManagerClient);
const ddbMock = mockClient(DynamoDBDocumentClient);

function conditionalFailure(): Error {
  return Object.assign(new Error('conditional'), {
    name: 'ConditionalCheckFailedException',
  });
}

/** Route the mocked fetch by URL: species lookup (GET) vs plant (POST). */
function mockFetch(species: { price: number; stock: number } | 'error', plantStatus = 200) {
  global.fetch = jest.fn(async (input: unknown) => {
    const url = String(input);
    if (url.includes('/api/species/')) {
      if (species === 'error') return { ok: false, status: 500 } as unknown as Response;
      return { ok: true, json: async () => species } as unknown as Response;
    }
    // /api/plant
    return {
      ok: plantStatus >= 200 && plantStatus < 300,
      status: plantStatus,
      json: async () => ({
        status: 'ok',
        trees: [
          {
            id: 999,
            token: 'tok',
            collect_url: 'https://tree-nation.com/collect/tok',
            certificate_url: 'https://tree-nation.com/certificate/tok',
            species_id: 1342,
          },
        ],
        payment_id: 5,
      }),
    } as unknown as Response;
  }) as unknown as typeof fetch;
}

beforeEach(() => {
  smMock.reset();
  ddbMock.reset();
  _resetTreeNationCachesForTest();
  process.env.TABLE_NAME = 'verdancy-test';
  process.env.TREENATION_API_TOKEN_SECRET_NAME = 'verdancy/treenation-token';
  process.env.TREENATION_SPECIES_ID = '1342';
  process.env.MAX_TREE_PRICE_EUR = '0.35';
  smMock.on(GetSecretValueCommand).resolves({ SecretString: 'live-token' });
});

describe('withinBudget (price guard, invariant: fail = do not spend)', () => {
  test('true when pinned species is at/under cap and in stock', async () => {
    mockFetch({ price: 0.35, stock: 16127 });
    expect(await withinBudget()).toBe(true);
  });

  test('false when price exceeds the cap', async () => {
    mockFetch({ price: 2, stock: 100 });
    expect(await withinBudget()).toBe(false);
  });

  test('false when out of stock', async () => {
    mockFetch({ price: 0.35, stock: 0 });
    expect(await withinBudget()).toBe(false);
  });

  test('false when the lookup cannot be verified', async () => {
    mockFetch('error');
    expect(await withinBudget()).toBe(false);
  });
});

describe('plantTrees', () => {
  test('does NOT call the plant endpoint when the guard fails', async () => {
    mockFetch({ price: 2, stock: 100 });
    const result = await plantTrees({ internalId: 'sub-1', quantity: 1 });
    expect(result).toBeNull();
    const calls = (global.fetch as jest.Mock).mock.calls.map((c) => String(c[0]));
    expect(calls.some((u) => u.includes('/api/plant'))).toBe(false);
  });

  test('plants with pinned species, Bearer token, and no email (no PII)', async () => {
    mockFetch({ price: 0.35, stock: 16127 });
    const result = await plantTrees({ internalId: 'sub-1', quantity: 10 });
    expect(result?.trees[0].collect_url).toContain('/collect/');

    const plantCall = (global.fetch as jest.Mock).mock.calls.find((c) =>
      String(c[0]).includes('/api/plant'),
    );
    expect(plantCall).toBeDefined();
    const [, init] = plantCall!;
    expect(init.headers.Authorization).toBe('Bearer live-token');
    const body = JSON.parse(init.body);
    expect(body.species_id).toBe(1342);
    expect(body.quantity).toBe(10);
    expect(body.recipients[0].email).toBeUndefined();
  });

  test('quantity 0 is a no-op that spends nothing', async () => {
    mockFetch({ price: 0.35, stock: 16127 });
    const result = await plantTrees({ internalId: 'sub-1', quantity: 0 });
    expect(result).toEqual({ trees: [] });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('throws on an API error so the caller can reconcile', async () => {
    mockFetch({ price: 0.35, stock: 16127 }, 500);
    await expect(plantTrees({ internalId: 'sub-1', quantity: 1 })).rejects.toThrow();
  });
});

describe('reserveGlobalTreeBudget (money circuit-breaker)', () => {
  test('true when under the daily max', async () => {
    ddbMock.on(UpdateCommand).resolves({});
    expect(await reserveGlobalTreeBudget(10, 500)).toBe(true);
  });

  test('false when the daily budget is exhausted', async () => {
    ddbMock.on(UpdateCommand).rejects(conditionalFailure());
    expect(await reserveGlobalTreeBudget(10, 500)).toBe(false);
  });

  test('n <= 0 reserves nothing and makes no write', async () => {
    expect(await reserveGlobalTreeBudget(0, 500)).toBe(true);
    expect(ddbMock.calls()).toHaveLength(0);
  });
});
