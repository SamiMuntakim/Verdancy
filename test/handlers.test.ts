import { mockClient } from 'aws-sdk-client-mock';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';
import { handler as routerHandler } from '../src/handlers/router';
import { handler as webhookHandler, _clearSecretCacheForTest } from '../src/handlers/webhook';

const smMock = mockClient(SecretsManagerClient);

function makeEvent(
  headers: Record<string, string>,
  method = 'POST',
  path = '/webhooks/revenuecat',
): APIGatewayProxyEventV2 {
  return {
    headers,
    requestContext: { http: { method, path } },
  } as unknown as APIGatewayProxyEventV2;
}

describe('router handler (Phase 2 shell)', () => {
  test('returns 501 and echoes the route', async () => {
    const res = (await routerHandler(
      makeEvent({}, 'GET', '/plants'),
    )) as APIGatewayProxyStructuredResultV2;
    expect(res.statusCode).toBe(501);
    expect(JSON.parse(res.body as string).route).toBe('GET /plants');
  });
});

describe('webhook handler — shared-secret verification', () => {
  const SECRET = 'super-secret-value-123';

  beforeEach(() => {
    smMock.reset();
    _clearSecretCacheForTest();
    process.env.REVENUECAT_WEBHOOK_SECRET_ARN =
      'arn:aws:secretsmanager:us-west-1:123456789012:secret:test';
    smMock.on(GetSecretValueCommand).resolves({ SecretString: SECRET });
  });

  test('401 when the Authorization header is missing', async () => {
    const res = (await webhookHandler(makeEvent({}))) as APIGatewayProxyStructuredResultV2;
    expect(res.statusCode).toBe(401);
  });

  test('401 when the secret is wrong', async () => {
    const res = (await webhookHandler(
      makeEvent({ authorization: 'not-the-secret' }),
    )) as APIGatewayProxyStructuredResultV2;
    expect(res.statusCode).toBe(401);
  });

  test('passes verification with the correct secret (501 shell for now)', async () => {
    const res = (await webhookHandler(
      makeEvent({ authorization: SECRET }),
    )) as APIGatewayProxyStructuredResultV2;
    expect(res.statusCode).toBe(501);
  });

  test('500 when the secret cannot be loaded', async () => {
    _clearSecretCacheForTest();
    smMock.on(GetSecretValueCommand).rejects(new Error('boom'));
    const res = (await webhookHandler(
      makeEvent({ authorization: SECRET }),
    )) as APIGatewayProxyStructuredResultV2;
    expect(res.statusCode).toBe(500);
  });
});
