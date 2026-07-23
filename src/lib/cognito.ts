import {
  CognitoIdentityProviderClient,
  AdminDeleteUserCommand,
  AdminGetUserCommand,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
  AdminInitiateAuthCommand,
  AdminRespondToAuthChallengeCommand,
  MessageActionType,
  type AttributeType,
} from '@aws-sdk/client-cognito-identity-provider';
import { randomBytes } from 'node:crypto';
import { requireEnv } from './env';

const client = new CognitoIdentityProviderClient({});

/**
 * Delete the Cognito user identity (account deletion, App Store Guideline
 * 5.1.1(v)). Cognito admin APIs accept the `sub` as the `Username`. Idempotent:
 * a missing user is treated as already deleted.
 */
export async function deleteCognitoUser(sub: string): Promise<void> {
  try {
    await client.send(
      new AdminDeleteUserCommand({
        UserPoolId: requireEnv('USER_POOL_ID'),
        Username: sub,
      }),
    );
  } catch (err) {
    if (err instanceof Error && err.name === 'UserNotFoundException') return;
    throw err;
  }
}

function attr(list: AttributeType[] | undefined, name: string): string | undefined {
  return list?.find((a) => a.Name === name)?.Value;
}

/**
 * A password that satisfies the pool policy (>=12 chars, all four classes). It is
 * set once on account creation and never used to sign in — the native flow mints
 * tokens through custom auth — so it exists only to move the account to CONFIRMED.
 */
function strongRandomPassword(): string {
  return `Aa1!${randomBytes(24).toString('base64url')}`;
}

export interface FederatedUser {
  /** The pool username — an email derived from the provider sub (see below). */
  username: string;
  /** The Cognito user-pool `sub` — the identity every backend route keys on. */
  sub: string;
  created: boolean;
}

/** Read the user-pool `sub` from a create or get result. AdminCreateUser returns
 * `User.Attributes`; AdminGetUser returns `UserAttributes`. Either way the internal
 * `Username` IS the sub when the pool signs in by email alias, so fall back to it. */
function subOf(
  user:
    | { Username?: string; Attributes?: AttributeType[]; UserAttributes?: AttributeType[] }
    | undefined,
): string {
  const sub = attr(user?.Attributes ?? user?.UserAttributes, 'sub') ?? user?.Username;
  if (!sub) throw new Error('Cognito user is missing its sub');
  return sub;
}

/**
 * Look up the pool user for a federated identity, creating it (suppressing all
 * Cognito messaging) on first sign-in. `username` MUST be an email, because the
 * pool signs in by email alias (`UsernameAttributes: ['email']`) — callers derive
 * a deterministic address from the provider sub, which makes this idempotent
 * across concurrent first sign-ins from the same person.
 */
export async function findOrCreateFederatedUser(username: string): Promise<FederatedUser> {
  const userPoolId = requireEnv('USER_POOL_ID');

  try {
    const existing = await client.send(
      new AdminGetUserCommand({ UserPoolId: userPoolId, Username: username }),
    );
    return { username, sub: subOf(existing), created: false };
  } catch (err) {
    if (!(err instanceof Error && err.name === 'UserNotFoundException')) throw err;
  }

  try {
    // The email attribute is derived from the username (the sign-in alias); we only
    // need to mark it verified so no verification flow is expected.
    const created = await client.send(
      new AdminCreateUserCommand({
        UserPoolId: userPoolId,
        Username: username,
        MessageAction: MessageActionType.SUPPRESS,
        UserAttributes: [{ Name: 'email_verified', Value: 'true' }],
      }),
    );
    await client.send(
      new AdminSetUserPasswordCommand({
        UserPoolId: userPoolId,
        Username: username,
        Password: strongRandomPassword(),
        Permanent: true,
      }),
    );
    return { username, sub: subOf(created.User), created: true };
  } catch (err) {
    // A concurrent first sign-in already created the user — fall back to reading it.
    if (err instanceof Error && err.name === 'UsernameExistsException') {
      const existing = await client.send(
        new AdminGetUserCommand({ UserPoolId: userPoolId, Username: username }),
      );
      return { username, sub: subOf(existing), created: false };
    }
    throw err;
  }
}

export interface IssuedTokens {
  idToken: string;
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

/**
 * Mint real user-pool tokens for `username` via the passwordless CUSTOM_AUTH
 * flow. The `brokerSecret` is the answer the VERIFY_AUTH_CHALLENGE trigger checks
 * — it proves this login came from our backend (which already verified the Apple
 * token), so a client calling CUSTOM_AUTH directly can't mint tokens.
 */
export async function issueTokensViaCustomAuth(
  username: string,
  brokerSecret: string,
): Promise<IssuedTokens> {
  const userPoolId = requireEnv('USER_POOL_ID');
  const clientId = requireEnv('APP_CLIENT_ID');

  const initiate = await client.send(
    new AdminInitiateAuthCommand({
      UserPoolId: userPoolId,
      ClientId: clientId,
      AuthFlow: 'CUSTOM_AUTH',
      AuthParameters: { USERNAME: username },
    }),
  );
  if (initiate.ChallengeName !== 'CUSTOM_CHALLENGE' || !initiate.Session) {
    throw new Error('Unexpected custom-auth initiation response');
  }

  const respond = await client.send(
    new AdminRespondToAuthChallengeCommand({
      UserPoolId: userPoolId,
      ClientId: clientId,
      ChallengeName: 'CUSTOM_CHALLENGE',
      Session: initiate.Session,
      ChallengeResponses: { USERNAME: username, ANSWER: brokerSecret },
    }),
  );
  const result = respond.AuthenticationResult;
  if (!result?.IdToken || !result.AccessToken || !result.RefreshToken) {
    throw new Error('Custom auth did not return tokens');
  }
  return {
    idToken: result.IdToken,
    accessToken: result.AccessToken,
    refreshToken: result.RefreshToken,
    expiresIn: result.ExpiresIn ?? 3600,
  };
}
