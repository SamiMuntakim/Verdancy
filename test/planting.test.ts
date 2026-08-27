jest.mock('../src/lib/treenation', () => ({ plantTrees: jest.fn() }));
jest.mock('../src/lib/dynamo', () => ({
  recordMilestoneIfNew: jest.fn(),
  releaseMilestone: jest.fn(),
  reserveGlobalTreeBudget: jest.fn(),
  releaseGlobalTreeBudget: jest.fn(),
  putTreeRecords: jest.fn(),
}));

import { grantTrees } from '../src/lib/planting';
import { plantTrees } from '../src/lib/treenation';
import {
  recordMilestoneIfNew,
  releaseMilestone,
  reserveGlobalTreeBudget,
  releaseGlobalTreeBudget,
  putTreeRecords,
} from '../src/lib/dynamo';

const mockPlant = plantTrees as jest.Mock;
const mockClaim = recordMilestoneIfNew as jest.Mock;
const mockRelease = releaseMilestone as jest.Mock;
const mockReserve = reserveGlobalTreeBudget as jest.Mock;
const mockReleaseBudget = releaseGlobalTreeBudget as jest.Mock;
const mockPutTrees = putTreeRecords as jest.Mock;

const okPlant = {
  trees: [{ id: 1, collect_url: 'c', certificate_url: 'cert' }],
  payment_id: 9,
};

beforeEach(() => {
  jest.clearAllMocks();
  mockClaim.mockResolvedValue(true);
  mockReserve.mockResolvedValue(true);
  mockPlant.mockResolvedValue(okPlant);
  mockRelease.mockResolvedValue(undefined);
  mockReleaseBudget.mockResolvedValue(undefined);
  mockPutTrees.mockResolvedValue(undefined);
});

const grant = (over: Partial<Parameters<typeof grantTrees>[0]> = {}) =>
  grantTrees({ sub: 'sub-1', milestoneId: 'streak_30', quantity: 1, reason: 'streak', ...over });

describe('grantTrees — exactly-once spending', () => {
  test('plants and records the trees on a fresh claim', async () => {
    expect(await grant()).toBe(true);
    expect(mockPlant).toHaveBeenCalledTimes(1);
    expect(mockPutTrees).toHaveBeenCalledWith('sub-1', okPlant.trees, 'streak');
  });

  test('a duplicate trigger does NOT plant (idempotent, no double spend)', async () => {
    mockClaim.mockResolvedValue(false); // milestone already claimed
    expect(await grant()).toBe(false);
    expect(mockPlant).not.toHaveBeenCalled();
    expect(mockReserve).not.toHaveBeenCalled();
  });

  test('claims BEFORE reserving budget and planting (ordering matters)', async () => {
    const order: string[] = [];
    mockClaim.mockImplementation(async () => (order.push('claim'), true));
    mockReserve.mockImplementation(async () => (order.push('reserve'), true));
    mockPlant.mockImplementation(async () => (order.push('plant'), okPlant));
    await grant();
    expect(order).toEqual(['claim', 'reserve', 'plant']);
  });
});

describe('grantTrees — circuit breaker and rollback', () => {
  test('budget exhausted → no plant, and the claim is rolled back for a retry', async () => {
    mockReserve.mockResolvedValue(false);
    expect(await grant({ quantity: 10 })).toBe(false);
    expect(mockPlant).not.toHaveBeenCalled();
    expect(mockRelease).toHaveBeenCalledWith('sub-1', 'streak_30', 10);
    // Budget was never consumed, so it must not be released.
    expect(mockReleaseBudget).not.toHaveBeenCalled();
  });

  test('price guard refusal → claim AND budget both rolled back', async () => {
    mockPlant.mockResolvedValue(null); // guard blocked the spend
    expect(await grant({ quantity: 10 })).toBe(false);
    expect(mockRelease).toHaveBeenCalledWith('sub-1', 'streak_30', 10);
    expect(mockReleaseBudget).toHaveBeenCalledWith(10);
  });

  test('a Tree-Nation error rolls back and never throws at the caller', async () => {
    mockPlant.mockRejectedValue(new Error('HTTP 500'));
    await expect(grant()).resolves.toBe(false);
    expect(mockRelease).toHaveBeenCalled();
  });

  // Once the trees are paid for, rolling back would let a retry buy them again.
  test('a record-write failure after planting does NOT roll back the claim', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    mockPutTrees.mockRejectedValue(new Error('dynamo down'));
    expect(await grant({ quantity: 10 })).toBe(true); // the trees exist — report success
    expect(mockRelease).not.toHaveBeenCalled(); // claim stands, so no re-plant
    expect(mockReleaseBudget).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  test('quantity 0 spends nothing and claims nothing', async () => {
    expect(await grant({ quantity: 0 })).toBe(false);
    expect(mockClaim).not.toHaveBeenCalled();
    expect(mockPlant).not.toHaveBeenCalled();
  });
});
