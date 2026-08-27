import { mockClient } from 'aws-sdk-client-mock';
import { DynamoDBDocumentClient, GetCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { recordCheckin } from '../src/lib/dynamo';

const ddbMock = mockClient(DynamoDBDocumentClient);

function conditionalFailure(): Error {
  return Object.assign(new Error('conditional'), { name: 'ConditionalCheckFailedException' });
}

const today = new Date().toISOString().slice(0, 10);
const yesterday = (() => {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
})();
const longAgo = '2020-01-01';

beforeEach(() => {
  ddbMock.reset();
  process.env.TABLE_NAME = 'verdancy-test';
});

/** The write the server would perform, if any. */
function updateInput() {
  const calls = ddbMock.commandCalls(UpdateCommand);
  return calls.length > 0 ? calls[0].args[0].input : undefined;
}

describe('recordCheckin — server-computed streak (client cannot assert one)', () => {
  test('first ever check-in starts the streak at 1', async () => {
    ddbMock.on(GetCommand).resolves({ Item: {} });
    ddbMock.on(UpdateCommand).resolves({});
    expect(await recordCheckin('sub-1')).toEqual({ streak: 1, advanced: true });
  });

  test('consecutive day increments the streak', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { last_active_date: yesterday, current_streak: 29 } });
    ddbMock.on(UpdateCommand).resolves({});
    expect(await recordCheckin('sub-1')).toEqual({ streak: 30, advanced: true });
  });

  test('a gap resets the streak to 1 (no credit for missed days)', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { last_active_date: longAgo, current_streak: 500 } });
    ddbMock.on(UpdateCommand).resolves({});
    expect(await recordCheckin('sub-1')).toEqual({ streak: 1, advanced: true });
  });

  test('second check-in the same day is a no-op — cannot farm days by spamming', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { last_active_date: today, current_streak: 7 } });
    const result = await recordCheckin('sub-1');
    expect(result).toEqual({ streak: 7, advanced: false });
    expect(ddbMock.commandCalls(UpdateCommand)).toHaveLength(0); // no write at all
  });

  test('concurrent same-day check-in loses the conditional write and does not advance', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { last_active_date: yesterday, current_streak: 4 } });
    ddbMock.on(UpdateCommand).rejects(conditionalFailure());
    const result = await recordCheckin('sub-1');
    expect(result.advanced).toBe(false);
  });

  test('the write is guarded by the SERVER date, never a client value', async () => {
    ddbMock.on(GetCommand).resolves({ Item: {} });
    ddbMock.on(UpdateCommand).resolves({});
    await recordCheckin('sub-1');
    const input = updateInput()!;
    expect(input.ConditionExpression).toContain('last_active_date < :today');
    expect(input.ExpressionAttributeValues![':today']).toBe(today);
  });
});
