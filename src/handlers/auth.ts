import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { json, parseJsonBody } from '../lib/http';
import { toErrorResponse } from '../lib/errors';
import { requireEnv } from '../lib/env';
import { verifyAppleIdentityToken } from '../lib/apple';
import { verifyGoogleIdToken } from '../lib/google';
import { findOrCreateFederatedUser, issueTokens } from '../lib/cognito';

/**
 * `POST /auth/apple` and `POST /auth/google` — native federated sign-in → real
 * Cognito user-pool tokens.
 *
 * These are UNAUTHENTICATED routes (no JWT authorizer, like the RevenueCat
 * webhook): each authenticates the caller by verifying the provider's identity
 * token against the provider's JWKS. The app runs the native sign-in, then POSTs
 * `{ identity_token, nonce }` here; we verify it, find-or-create the pool user, and
 * mint tokens via the admin password flow. The app uses/refreshes those tokens
 * directly against Cognito — every other route keeps its User-Pool JWT authorizer.
 *
 * Federated accounts use a deterministic email-username derived from the provider
 * sub (the pool signs in by email alias, so the username must be an email). Keying
 * on the provider sub keeps it stable and keeps each provider in its own username
 * space, so Apple / Google / email-password sign-ups never collide. Downstream
 * identity is always the Cognito-assigned `sub`.
 */
interface AuthBody {
  identity_token?: string;
  nonce?: string;
}

interface Identity {
  sub: string;
}

/** Verify the provider token for the given route, returning the provider's sub. */
async function verifyForRoute(path: string, idToken: string, nonce: string): Promise<Identity> {
  if (path.endsWith('/auth/apple')) {
    return verifyAppleIdentityToken(idToken, {
      audience: requireEnv('APPLE_AUDIENCE'),
      expectedNonce: nonce,
    });
  }
  if (path.endsWith('/auth/google')) {
    return verifyGoogleIdToken(idToken, {
      audience: requireEnv('GOOGLE_CLIENT_ID'),
      expectedNonce: nonce,
    });
  }
  return Promise.reject(new Error(`Unknown auth route: ${path}`));
}

function providerFor(path: string): string | undefined {
  if (path.endsWith('/auth/apple')) return 'apple';
  if (path.endsWith('/auth/google')) return 'google';
  return undefined;
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  try {
    const path = event.rawPath || event.requestContext.http.path;
    const provider = providerFor(path);
    if (!provider) return json(404, { error: 'Not found' });

    let body: AuthBody;
    try {
      body = parseJsonBody<AuthBody>(event);
    } catch {
      return json(400, { error: 'Invalid JSON body' });
    }

    const idToken = body.identity_token;
    const nonce = body.nonce;
    if (!idToken || !nonce) {
      return json(400, { error: 'Missing identity_token or nonce' });
    }

    // Any verification failure throws ApiError(401), mapped to a clean 401 below.
    const identity = await verifyForRoute(path, idToken, nonce);

    const username = `${provider}_${identity.sub.replace(/[^A-Za-z0-9]/g, '')}@no-reply.verdancy.app`;
    const user = await findOrCreateFederatedUser(username);
    const tokens = await issueTokens(user.username);

    return json(200, {
      id_token: tokens.idToken,
      access_token: tokens.accessToken,
      refresh_token: tokens.refreshToken,
      expires_in: tokens.expiresIn,
      token_type: 'Bearer',
    });
  } catch (err) {
    return toErrorResponse(err);
  }
};
