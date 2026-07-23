import { mockClient } from 'aws-sdk-client-mock';
import {
  CognitoIdentityProviderClient,
  AdminGetUserCommand,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
  AdminInitiateAuthCommand,
  AdminRespondToAuthChallengeCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';

// Apple verification is exercised on its own in apple.test.ts; here we control its
// result to test the handler's orchestration.
jest.mock('../src/lib/apple', () => ({ verifyAppleIdentityToken: jest.fn() }));
import { verifyAppleIdentityToken } from '../src/lib/apple';
import { ApiError } from '../src/lib/errors';
import { handler } from '../src/handlers/auth';
import { _clearSecretCacheForTest } from '../src/lib/secrets';

const cognitoMock = mockClient(CognitoIdentityProviderClient);
const smMock = mockClient(SecretsManagerClient);
const verifyMock = verifyAppleIdentityToken as jest.MockedFunction<typeof verifyAppleIdentityToken>;

const BROKER_SECRET = 'broker-secret-value';

function userNotFound(): Error {
  const e = new Error('no such user');
  e.name = 'UserNotFoundException';
  return e;
}

function event(body?: unknown): APIGatewayProxyEventV2 {
  return {
    headers: {},
    body: body === undefined ? undefined : JSON.stringify(body),
    isBase64Encoded: false,
    requestContext: { http: { method: 'POST', path: '/auth/apple' } },
  } as unknown as APIGatewayProxyEventV2;
}

async function call(body?: unknown) {
  return (await handler(event(body))) as APIGatewayProxyStructuredResultV2;
}

beforeAll(() => {
  process.env.USER_POOL_ID = 'us-west-1_test';
  process.env.APP_CLIENT_ID = 'client-abc';
  process.env.APPLE_AUDIENCE = 'com.verdancy.app';
  process.env.AUTH_BROKER_SECRET_ARN = 'arn:aws:secretsmanager:us-west-1:123:secret:broker';
});

beforeEach(() => {
  cognitoMock.reset();
  smMock.reset();
  _clearSecretCacheForTest();
  verifyMock.mockReset();
  verifyMock.mockResolvedValue({
    sub: 'apple-sub-1',
    email: 'user@example.com',
    emailVerified: true,
    isPrivateEmail: false,
  });
  smMock.on(GetSecretValueCommand).resolves({ SecretString: BROKER_SECRET });
  // Default: the user already exists. The "new user" block overrides this.
  cognitoMock.on(AdminGetUserCommand).resolves({
    UserAttributes: [{ Name: 'sub', Value: 'cognito-sub-1' }],
  });
  cognitoMock.on(AdminSetUserPasswordCommand).resolves({});
  cognitoMock.on(AdminInitiateAuthCommand).resolves({
    ChallengeName: 'CUSTOM_CHALLENGE',
    Session: 'session-xyz',
  });
  cognitoMock.on(AdminRespondToAuthChallengeCommand).resolves({
    AuthenticationResult: {
      IdToken: 'id-tok',
      AccessToken: 'access-tok',
      RefreshToken: 'refresh-tok',
      ExpiresIn: 3600,
    },
  });
});

const goodBody = { identity_token: 'apple.jwt.here', nonce: 'raw-nonce' };

describe('input validation', () => {
  test('400 when identity_token is missing', async () => {
    const res = await call({ nonce: 'raw-nonce' });
    expect(res.statusCode).toBe(400);
    expect(verifyMock).not.toHaveBeenCalled();
  });

  test('400 when nonce is missing', async () => {
    const res = await call({ identity_token: 'apple.jwt.here' });
    expect(res.statusCode).toBe(400);
    expect(verifyMock).not.toHaveBeenCalled();
  });

  test('400 on invalid JSON', async () => {
    const res = (await handler({
      ...event(),
      body: '{not json',
    } as APIGatewayProxyEventV2)) as APIGatewayProxyStructuredResultV2;
    expect(res.statusCode).toBe(400);
  });
});

describe('token verification failures', () => {
  test('401 when Apple verification rejects', async () => {
    verifyMock.mockRejectedValue(new ApiError(401, 'Invalid token signature'));
    const res = await call(goodBody);
    expect(res.statusCode).toBe(401);
    // No user is created when the token is bad.
    expect(cognitoMock.commandCalls(AdminCreateUserCommand)).toHaveLength(0);
  });

  test('passes the raw nonce and audience through to verification', async () => {
    await call(goodBody);
    expect(verifyMock).toHaveBeenCalledWith('apple.jwt.here', {
      audience: 'com.verdancy.app',
      expectedNonce: 'raw-nonce',
    });
  });
});

describe('new user (first sign-in)', () => {
  beforeEach(() => {
    cognitoMock.on(AdminGetUserCommand).rejects(userNotFound());
    cognitoMock.on(AdminCreateUserCommand).resolves({
      User: { Attributes: [{ Name: 'sub', Value: 'cognito-sub-1' }] },
    });
  });

  test('creates the user, sets a password, and mints tokens', async () => {
    const res = await call(goodBody);
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body!)).toEqual({
      id_token: 'id-tok',
      access_token: 'access-tok',
      refresh_token: 'refresh-tok',
      expires_in: 3600,
      token_type: 'Bearer',
    });
    expect(cognitoMock.commandCalls(AdminCreateUserCommand)).toHaveLength(1);
    expect(cognitoMock.commandCalls(AdminSetUserPasswordCommand)).toHaveLength(1);

    // Username keys on the Apple sub; the create suppresses Cognito messaging.
    const create = cognitoMock.commandCalls(AdminCreateUserCommand)[0].args[0].input;
    expect(create.Username).toBe('SignInWithApple_apple-sub-1');
    expect(create.MessageAction).toBe('SUPPRESS');
  });

  test('answers the custom challenge with the broker secret', async () => {
    await call(goodBody);
    const respond = cognitoMock.commandCalls(AdminRespondToAuthChallengeCommand)[0].args[0].input;
    expect(respond.ChallengeResponses?.ANSWER).toBe(BROKER_SECRET);
    expect(respond.ChallengeResponses?.USERNAME).toBe('SignInWithApple_apple-sub-1');
  });
});

describe('returning user', () => {
  test('does not re-create an existing user', async () => {
    cognitoMock.on(AdminGetUserCommand).resolves({
      UserAttributes: [{ Name: 'sub', Value: 'cognito-sub-1' }],
    });
    const res = await call(goodBody);
    expect(res.statusCode).toBe(200);
    expect(cognitoMock.commandCalls(AdminCreateUserCommand)).toHaveLength(0);
    expect(cognitoMock.commandCalls(AdminSetUserPasswordCommand)).toHaveLength(0);
  });
});
