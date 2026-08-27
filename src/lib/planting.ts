import { intEnv } from './env';
import { plantTrees } from './treenation';
import {
  recordMilestoneIfNew,
  releaseMilestone,
  reserveGlobalTreeBudget,
  releaseGlobalTreeBudget,
  putTreeRecords,
} from './dynamo';

/**
 * The one place trees are actually planted. Every tree Verdancy funds goes
 * through `grantTrees`, in this order:
 *
 *   1. **Claim** the milestone with a single atomic conditional write. A
 *      duplicate/retried trigger loses the claim and returns without spending —
 *      this is what makes planting exactly-once (invariant #5's discipline
 *      applied to money).
 *   2. **Reserve** global daily budget — the circuit breaker that bounds a
 *      runaway bug (Tree-Nation auto-refill can't be disabled).
 *   3. **Plant** via Tree-Nation, which independently re-checks the per-tree
 *      price ceiling and refuses to spend if it can't verify it.
 *   4. **Roll back** the claim + budget if the plant didn't happen, so a later
 *      retry can re-claim rather than silently losing the user's tree.
 *
 * Never throws: a planting failure must never fail the user request or the
 * webhook ack that triggered it.
 */

const DAILY_TREE_BUDGET = (): number => intEnv('DAILY_TREE_BUDGET', 30);

export async function grantTrees(opts: {
  sub: string;
  milestoneId: string;
  quantity: number;
  reason: string;
  message?: string;
}): Promise<boolean> {
  const { sub, milestoneId, quantity, reason, message } = opts;
  if (quantity <= 0) return false;

  let claimed = false;
  let reserved = false;
  try {
    claimed = await recordMilestoneIfNew(sub, milestoneId, quantity);
    if (!claimed) return false; // already granted — idempotent, no spend

    reserved = await reserveGlobalTreeBudget(quantity, DAILY_TREE_BUDGET());
    if (!reserved) {
      console.error(`Tree budget exhausted for today; skipped ${quantity} tree(s) (${reason})`);
      await rollback(sub, milestoneId, quantity, false);
      return false;
    }

    const result = await plantTrees({ internalId: sub, quantity, message });
    if (!result) {
      // Price guard refused — nothing was spent.
      await rollback(sub, milestoneId, quantity, true);
      return false;
    }

    await putTreeRecords(sub, result.trees, reason);
    return true;
  } catch (err) {
    console.error(`Tree planting failed (${reason}):`, err instanceof Error ? err.message : err);
    if (claimed) await rollback(sub, milestoneId, quantity, reserved);
    return false;
  }
}

async function rollback(
  sub: string,
  milestoneId: string,
  quantity: number,
  releaseBudget: boolean,
): Promise<void> {
  try {
    await releaseMilestone(sub, milestoneId, quantity);
    if (releaseBudget) await releaseGlobalTreeBudget(quantity);
  } catch {
    console.error('Tree grant rollback failed');
  }
}
