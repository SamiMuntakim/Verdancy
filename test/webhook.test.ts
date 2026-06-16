import { mockClient } from 'aws-sdk-client-mock';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { DynamoDBDocumentClient, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';
import { handler, _clearSecretCacheForTest } from '../src/handlers/webhook';

const smMock = mockClient(SecretsManagerClient);
const ddbMock = mockClient(DynamoDBDocumentClient);

const SECRET = 'webhook-shared-secret';

function event(headers: Record<string, string>, body?: unknown): APIGatewayProxyEventV2 {
  return {
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    isBase64Encoded: false,
    requestContext: { http: { method: 'POST', path: '/webhooks/revenuecat' } },
  } as unknown as APIGatewayProxyEventV2;
}

beforeAll(() => {
  process.env.TABLE_NAME = 'VerdancyData';
  process.env.REVENUECAT_WEBHOOK_SECRET_ARN = 'arn:aws:secretsmanager:us-west-1:123:secret:wh';
});

beforeEach(() => {
  smMock.reset();
  ddbMock.reset();
  _clearSecretCacheForTest();
  smMock.on(GetSecretValueCommand).resolves({ SecretString: SECRET });
  ddbMock.on(UpdateCommand).resolves({});
});

async function call(headers: Record<string, string>, body?: unknown) {
  return (await handler(event(headers, body))) as APIGatewayProxyStructuredResultV2;
}

describe('secret verification', () => {
  test('401 when Authorization missing', async () => {
    const res = await call({});
    expect(res.statusCode).toBe(401);
    expect(ddbMock.commandCalls(UpdateCommand)).toHaveLength(0);
  });

  test('401 when secret is wrong', async () => {
    const res = await call(
      { authorization: 'nope' },
      { event: { type: 'RENEWAL', app_user_id: 'u' } },
    );
    expect(res.statusCode).toBe(401);
    expect(ddbMock.commandCalls(UpdateCommand)).toHaveLength(0);
  });

  test('500 when the secret cannot be loaded', async () => {
    smMock.on(GetSecretValueCommand).rejects(new Error('boom'));
    const res = await call(
      { authorization: SECRET },
      { event: { type: 'RENEWAL', app_user_id: 'u' } },
    );
    expect(res.statusCode).toBe(500);
  });
});

describe('entitlement updates (PRD 4.6)', () => {
  test('INITIAL_PURCHASE activates entitlement with expiry', async () => {
    const res = await call(
      { authorization: SECRET },
      {
        event: {
          type: 'INITIAL_PURCHASE',
          app_user_id: 'sub-1',
          expiration_at_ms: 1_700_000_000_000,
        },
      },
    );
    expect(res.statusCode).toBe(200);
    const calls = ddbMock.commandCalls(UpdateCommand);
    expect(calls).toHaveLength(1);
    const input = calls[0].args[0].input;
    expect(input.Key).toEqual({ PK: 'USER#sub-1', SK: 'METADATA' });
    expect(input.ExpressionAttributeValues?.[':active']).toBe(true);
    expect(input.ExpressionAttributeValues?.[':exp']).toBe(1_700_000_000);
  });

  test('EXPIRATION deactivates entitlement', async () => {
    const res = await call(
      { authorization: SECRET },
      { event: { type: 'EXPIRATION', app_user_id: 'sub-1' } },
    );
    expect(res.statusCode).toBe(200);
    const input = ddbMock.commandCalls(UpdateCommand)[0].args[0].input;
    expect(input.ExpressionAttributeValues?.[':active']).toBe(false);
  });

  test('400 when event/app_user_id missing (no write)', async () => {
    const res = await call({ authorization: SECRET }, {});
    expect(res.statusCode).toBe(400);
    expect(ddbMock.commandCalls(UpdateCommand)).toHaveLength(0);
  });

  test('unknown event type is acknowledged without a write', async () => {
    const res = await call(
      { authorization: SECRET },
      { event: { type: 'TEST', app_user_id: 'sub-1' } },
    );
    expect(res.statusCode).toBe(200);
    expect(ddbMock.commandCalls(UpdateCommand)).toHaveLength(0);
  });
});
