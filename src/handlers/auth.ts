import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { json, parseJsonBody } from '../lib/http';
import { toErrorResponse } from '../lib/errors';
import { requireEnv } from '../lib/env';
import { verifyAppleIdentityToken } from '../lib/apple';
import { findOrCreateFederatedUser, issueTokensViaCustomAuth } from '../lib/cognito';
import { getSecretString } from '../lib/secrets';

/**
 * `POST /auth/apple` — native Sign in with Apple → real Cognito user-pool tokens.
 *
 * This is an UNAUTHENTICATED route (no JWT authorizer, like the RevenueCat
 * webhook): it authenticates the caller by verifying Apple's identity token
 * against Apple's JWKS. The app runs `ASAuthorizationController` natively (system
 * sheet, no web prompt), then POSTs the identity token + raw nonce here; we verify
 * it, find-or-create the pool user, and mint tokens via the passwordless
 * custom-auth flow. The app then uses/refreshes those tokens directly against
 * Cognito — every other route keeps its User-Pool JWT authorizer unchanged.
 */
interface AppleAuthBody {
  identity_token?: string;
  nonce?: string;
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  try {
    let body: AppleAuthBody;
    try {
      body = parseJsonBody<AppleAuthBody>(event);
    } catch {
      return json(400, { error: 'Invalid JSON body' });
    }

    const idToken = body.identity_token;
    const nonce = body.nonce;
    if (!idToken || !nonce) {
      return json(400, { error: 'Missing identity_token or nonce' });
    }

    // Verify Apple's token (signature + iss/aud/exp + anti-replay nonce). Any
    // failure throws an ApiError(401), mapped to a clean 401 below.
    const identity = await verifyAppleIdentityToken(idToken, {
      audience: requireEnv('APPLE_AUDIENCE'),
      expectedNonce: nonce,
    });

    // The pool signs in by email alias, so the Cognito username must be an email.
    // Apple's own email isn't a stable key (absent on repeat authorizations, and a
    // "Hide My Email" relay can rotate), so derive a deterministic address from the
    // stable Apple sub and use it as the account handle. Downstream identity is the
    // Cognito-assigned sub, unchanged.
    const username = `apple_${identity.sub.replace(/[^A-Za-z0-9]/g, '')}@no-reply.verdancy.app`;
    const user = await findOrCreateFederatedUser(username);

    const brokerSecret = await getSecretString(requireEnv('AUTH_BROKER_SECRET_ARN'));
    const tokens = await issueTokensViaCustomAuth(user.username, brokerSecret);

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
