import {
  CognitoIdentityProviderClient,
  AdminDeleteUserCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { requireEnv } from './env';

/**
 * Delete the Cognito user identity (account deletion, App Store Guideline
 * 5.1.1(v)). Cognito admin APIs accept the `sub` as the `Username`. Idempotent:
 * a missing user is treated as already deleted.
 */
const client = new CognitoIdentityProviderClient({});

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
