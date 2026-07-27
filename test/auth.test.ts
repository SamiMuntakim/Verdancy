import { mockClient } from 'aws-sdk-client-mock';
import {
  CognitoIdentityProviderClient,
  AdminGetUserCommand,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
  AdminInitiateAuthCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';

// Provider verification is exercised on its own in apple.test.ts / google.test.ts;
// here we control the result to test the handler's orchestration.
jest.mock('../src/lib/apple', () => ({ verifyAppleIdentityToken: jest.fn() }));
jest.mock('../src/lib/google', () => ({ verifyGoogleIdToken: jest.fn() }));
import { verifyAppleIdentityToken } from '../src/lib/apple';
import { verifyGoogleIdToken } from '../src/lib/google';
import { ApiError } from '../src/lib/errors';
import { handler } from '../src/handlers/auth';

const cognitoMock = mockClient(CognitoIdentityProviderClient);
const verifyMock = verifyAppleIdentityToken as jest.MockedFunction<typeof verifyAppleIdentityToken>;
const verifyGoogleMock = verifyGoogleIdToken as jest.MockedFunction<typeof verifyGoogleIdToken>;

function userNotFound(): Error {
  const e = new Error('no such user');
  e.name = 'UserNotFoundException';
  return e;
}

function event(body?: unknown, path = '/auth/apple'): APIGatewayProxyEventV2 {
  return {
    rawPath: path,
    headers: {},
    body: body === undefined ? undefined : JSON.stringify(body),
    isBase64Encoded: false,
    requestContext: { http: { method: 'POST', path } },
  } as unknown as APIGatewayProxyEventV2;
}

async function call(body?: unknown, path = '/auth/apple') {
  return (await handler(event(body, path))) as APIGatewayProxyStructuredResultV2;
}

beforeAll(() => {
  process.env.USER_POOL_ID = 'us-west-1_test';
  process.env.APP_CLIENT_ID = 'client-abc';
  process.env.APPLE_AUDIENCE = 'com.verdancy.app';
  process.env.GOOGLE_CLIENT_ID = '463079233513-abc.apps.googleusercontent.com';
});

beforeEach(() => {
  cognitoMock.reset();
  verifyMock.mockReset();
  verifyMock.mockResolvedValue({
    sub: 'apple-sub-1',
    email: 'user@example.com',
    emailVerified: true,
    isPrivateEmail: false,
  });
  verifyGoogleMock.mockReset();
  verifyGoogleMock.mockResolvedValue({
    sub: 'google-sub-1',
    email: 'user@gmail.com',
    emailVerified: true,
  });
  // Default: the user already exists. The "new user" block overrides this.
  cognitoMock.on(AdminGetUserCommand).resolves({
    UserAttributes: [{ Name: 'sub', Value: 'cognito-sub-1' }],
  });
  cognitoMock.on(AdminSetUserPasswordCommand).resolves({});
  cognitoMock.on(AdminInitiateAuthCommand).resolves({
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

    // Username is an email derived from the Apple sub (the pool signs in by email
    // alias); the create suppresses Cognito messaging.
    const create = cognitoMock.commandCalls(AdminCreateUserCommand)[0].args[0].input;
    expect(create.Username).toBe('apple_applesub1@no-reply.verdancy.app');
    expect(create.MessageAction).toBe('SUPPRESS');
  });

  test('still creates the account when Apple omits the email (repeat authorization)', async () => {
    // Apple sends no email on repeat authorizations — the username comes from the
    // sub, not the email, so this must still succeed.
    verifyMock.mockResolvedValue({
      sub: 'apple.sub.2',
      email: undefined,
      emailVerified: false,
      isPrivateEmail: false,
    });
    const res = await call(goodBody);
    expect(res.statusCode).toBe(200);
    const create = cognitoMock.commandCalls(AdminCreateUserCommand)[0].args[0].input;
    expect(create.Username).toBe('apple_applesub2@no-reply.verdancy.app');
  });

  test('mints tokens with ADMIN_USER_PASSWORD_AUTH using a set ephemeral password', async () => {
    await call(goodBody);
    const setPw = cognitoMock.commandCalls(AdminSetUserPasswordCommand)[0].args[0].input;
    expect(setPw.Permanent).toBe(true);
    expect(setPw.Password).toBeTruthy();

    const auth = cognitoMock.commandCalls(AdminInitiateAuthCommand)[0].args[0].input;
    expect(auth.AuthFlow).toBe('ADMIN_USER_PASSWORD_AUTH');
    expect(auth.AuthParameters?.USERNAME).toBe('apple_applesub1@no-reply.verdancy.app');
    // The password used to sign in is the one just set (never returned to the app).
    expect(auth.AuthParameters?.PASSWORD).toBe(setPw.Password);
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
    // Tokens are still minted (password set + admin auth) for the existing user.
    expect(cognitoMock.commandCalls(AdminInitiateAuthCommand)).toHaveLength(1);
  });
});

describe('POST /auth/google', () => {
  beforeEach(() => {
    cognitoMock.on(AdminGetUserCommand).rejects(userNotFound());
    cognitoMock.on(AdminCreateUserCommand).resolves({
      User: { Attributes: [{ Name: 'sub', Value: 'cognito-sub-2' }] },
    });
  });

  test('verifies with Google (not Apple) and derives a google_ username', async () => {
    const res = await call(goodBody, '/auth/google');
    expect(res.statusCode).toBe(200);
    expect(verifyGoogleMock).toHaveBeenCalledWith('apple.jwt.here', {
      audience: '463079233513-abc.apps.googleusercontent.com',
      expectedNonce: 'raw-nonce',
    });
    expect(verifyMock).not.toHaveBeenCalled();
    const create = cognitoMock.commandCalls(AdminCreateUserCommand)[0].args[0].input;
    expect(create.Username).toBe('google_googlesub1@no-reply.verdancy.app');
  });

  test('401 when the Google token is invalid', async () => {
    verifyGoogleMock.mockRejectedValue(new ApiError(401, 'Bad token signature'));
    const res = await call(goodBody, '/auth/google');
    expect(res.statusCode).toBe(401);
  });
});
