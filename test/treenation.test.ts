import { mockClient } from 'aws-sdk-client-mock';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { DynamoDBDocumentClient, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import {
  withinBudget,
  plantTrees,
  fetchProjectPricing,
  _resetTreeNationCachesForTest,
} from '../src/lib/treenation';
import { reserveGlobalTreeBudget } from '../src/lib/dynamo';

const smMock = mockClient(SecretsManagerClient);
const ddbMock = mockClient(DynamoDBDocumentClient);

function conditionalFailure(): Error {
  return Object.assign(new Error('conditional'), {
    name: 'ConditionalCheckFailedException',
  });
}

type SpeciesRow = { id: number; name?: string; price: number; stock: number };

/**
 * Route the mocked fetch by URL: project species list (GET) vs plant (POST).
 * `plantedSpeciesId` lets a test simulate Tree-Nation substituting a species.
 */
function mockFetch(
  species: SpeciesRow[] | 'error' | 'malformed',
  opts: { plantStatus?: number; plantedSpeciesId?: number } = {},
) {
  const { plantStatus = 200, plantedSpeciesId } = opts;
  global.fetch = jest.fn(async (input: unknown, init?: { body?: string }) => {
    const url = String(input);
    if (url.includes('/species')) {
      if (species === 'error') return { ok: false, status: 500 } as unknown as Response;
      if (species === 'malformed') {
        return { ok: true, json: async () => [{ id: 1, price: 'oops' }] } as unknown as Response;
      }
      return { ok: true, json: async () => species } as unknown as Response;
    }
    // /api/plant — echoes back the requested species unless told to substitute.
    const requested = JSON.parse(init?.body ?? '{}');
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
            species_id: plantedSpeciesId ?? requested.species_id,
            species_name: 'Ceriops tagal',
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
  process.env.TREENATION_PROJECT_ID = '269';
  process.env.TARGET_TREE_PRICE_EUR = '0.35';
  process.env.MAX_TREE_PRICE_EUR = '0.5';
  smMock.on(GetSecretValueCommand).resolves({ SecretString: 'live-token' });
});

// We ask for the cheapest in-stock species, but Tree-Nation can substitute, so
// the guard bounds the WORST case across everything it could pick.
describe('withinBudget (worst-case guard, invariant: fail = do not spend)', () => {
  test('true when every in-stock species is at/under the cap', async () => {
    mockFetch([
      { id: 3657, price: 0.35, stock: 48544 },
      { id: 2086, price: 0.5, stock: 74142 },
    ]);
    expect(await withinBudget()).toBe(true);
  });

  test('false when ANY in-stock species exceeds the substitution ceiling', async () => {
    mockFetch([
      { id: 3657, price: 0.35, stock: 48544 },
      { id: 56, price: 14, stock: 500 }, // a stock-out could substitute this one
    ]);
    expect(await withinBudget()).toBe(false);
  });

  test('false when even the cheapest species is above the target price', async () => {
    // Everything within the substitution ceiling, but nothing at our target.
    mockFetch([{ id: 2086, price: 0.5, stock: 74142 }]);
    expect(await withinBudget()).toBe(false);
  });

  test('an out-of-stock expensive species is ignored (it cannot be picked)', async () => {
    mockFetch([
      { id: 3657, price: 0.35, stock: 48544 },
      { id: 56, price: 14, stock: 0 },
    ]);
    expect(await withinBudget()).toBe(true);
  });

  test('false when nothing is in stock at all', async () => {
    mockFetch([{ id: 3657, price: 0.35, stock: 0 }]);
    expect(await withinBudget()).toBe(false);
  });

  test('false when the lookup cannot be verified', async () => {
    mockFetch('error');
    expect(await withinBudget()).toBe(false);
  });

  test('false on a malformed entry — a bad price could be hiding a real one', async () => {
    mockFetch('malformed');
    expect(await withinBudget()).toBe(false);
  });
});

describe('fetchProjectPricing (cheapest selection)', () => {
  test('picks the cheapest IN-STOCK species, not the cheapest overall', async () => {
    mockFetch([
      { id: 1342, name: 'Albizia gummifera', price: 0.2, stock: 0 }, // cheapest but unplantable
      { id: 3657, name: 'Ceriops tagal', price: 0.35, stock: 124986 },
      { id: 2086, name: 'Ocotea usambarensis', price: 0.5, stock: 74142 },
    ]);
    const pricing = await fetchProjectPricing();
    expect(pricing?.cheapest.id).toBe(3657);
    expect(pricing?.cheapest.price).toBe(0.35);
    expect(pricing?.worstCase).toBe(0.5);
  });
});

const inStock: SpeciesRow[] = [
  { id: 3657, name: 'Ceriops tagal', price: 0.35, stock: 124986 },
  { id: 2086, name: 'Ocotea usambarensis', price: 0.5, stock: 74142 },
];

describe('plantTrees', () => {
  test('does NOT call the plant endpoint when the guard fails', async () => {
    mockFetch([{ id: 56, price: 2, stock: 100 }]);
    const result = await plantTrees({ internalId: 'sub-1', quantity: 1 });
    expect(result).toBeNull();
    const calls = (global.fetch as jest.Mock).mock.calls.map((c) => String(c[0]));
    expect(calls.some((u) => u.includes('/api/plant'))).toBe(false);
  });

  test('plants with the Bearer token and no email (no PII leaves our system)', async () => {
    mockFetch(inStock);
    const result = await plantTrees({ internalId: 'sub-1', quantity: 10 });
    expect(result?.trees[0].collect_url).toContain('/collect/');

    const plantCall = (global.fetch as jest.Mock).mock.calls.find((c) =>
      String(c[0]).includes('/api/plant'),
    );
    expect(plantCall).toBeDefined();
    const [, init] = plantCall!;
    expect(init.headers.Authorization).toBe('Bearer live-token');
    const body = JSON.parse(init.body);
    expect(body.quantity).toBe(10);
    expect(body.recipients[0].internal_id).toBe('sub-1');
    expect(body.recipients[0].email).toBeUndefined();
  });

  test('requests the CHEAPEST in-stock species (0.35, not the 0.50 one)', async () => {
    mockFetch(inStock);
    await plantTrees({ internalId: 'sub-1', quantity: 1 });
    const plantCall = (global.fetch as jest.Mock).mock.calls.find((c) =>
      String(c[0]).includes('/api/plant'),
    );
    expect(JSON.parse(plantCall![1].body).species_id).toBe(3657);
  });

  test('never requests an out-of-stock species — that is what triggers substitution', async () => {
    mockFetch([
      { id: 1342, price: 0.35, stock: 0 }, // the id we used to hardcode
      { id: 3657, price: 0.35, stock: 124986 },
    ]);
    await plantTrees({ internalId: 'sub-1', quantity: 1 });
    const plantCall = (global.fetch as jest.Mock).mock.calls.find((c) =>
      String(c[0]).includes('/api/plant'),
    );
    expect(JSON.parse(plantCall![1].body).species_id).toBe(3657);
  });

  test('logs loudly when Tree-Nation substitutes a different species', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    mockFetch(inStock, { plantedSpeciesId: 2086 }); // we asked 3657, got the 0.50 one
    const result = await plantTrees({ internalId: 'sub-1', quantity: 1 });
    expect(result?.trees[0].species_id).toBe(2086);
    expect(spy).toHaveBeenCalledWith(expect.stringContaining('substituted species'));
    spy.mockRestore();
  });

  test('stays quiet when it gets the species it asked for', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    mockFetch(inStock);
    await plantTrees({ internalId: 'sub-1', quantity: 1 });
    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  test('a substitution drops the stale listing so the next plant re-reads stock', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    mockFetch(inStock, { plantedSpeciesId: 2086 });
    await plantTrees({ internalId: 'sub-1', quantity: 1 });
    const listingCallsBefore = (global.fetch as jest.Mock).mock.calls.filter((c) =>
      String(c[0]).includes('/species'),
    ).length;

    // Without cache invalidation this second plant would reuse the stale listing.
    await plantTrees({ internalId: 'sub-2', quantity: 1 });
    const listingCallsAfter = (global.fetch as jest.Mock).mock.calls.filter((c) =>
      String(c[0]).includes('/species'),
    ).length;
    expect(listingCallsAfter).toBeGreaterThan(listingCallsBefore);
    spy.mockRestore();
  });

  test('quantity 0 is a no-op that spends nothing', async () => {
    mockFetch(inStock);
    const result = await plantTrees({ internalId: 'sub-1', quantity: 0 });
    expect(result).toEqual({ trees: [] });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('throws on an API error so the caller can reconcile', async () => {
    mockFetch(inStock, { plantStatus: 500 });
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
