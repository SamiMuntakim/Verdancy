import type {
  APIGatewayProxyEventV2,
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyStructuredResultV2,
} from 'aws-lambda';

/**
 * Build a clean JSON HTTP-API response. Statuses are constrained to the set the
 * PRD allows: 200 / 400 / 401 / 402 / 403 / 404 / 429 / 500 (plus 501 for the
 * not-yet-implemented shells).
 */
export function json(statusCode: number, body: unknown): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  };
}

/**
 * The caller's identity — ONLY ever the verified JWT `sub` from the authorizer.
 * Never read identity from the body, query string, or any client-supplied field
 * (hard invariant #1).
 */
export function getSub(event: APIGatewayProxyEventV2WithJWTAuthorizer): string {
  const sub = event.requestContext.authorizer?.jwt?.claims?.sub;
  if (typeof sub !== 'string' || sub.length === 0) {
    // The JWT authorizer should guarantee this; defensive 401 otherwise.
    throw new Error('Missing sub claim');
  }
  return sub;
}

/** The caller's email claim, if present (used for profile upsert — not identity). */
export function getEmailClaim(event: APIGatewayProxyEventV2WithJWTAuthorizer): string | undefined {
  const email = event.requestContext.authorizer?.jwt?.claims?.email;
  return typeof email === 'string' ? email : undefined;
}

export function parseJsonBody<T = Record<string, unknown>>(event: APIGatewayProxyEventV2): T {
  if (!event.body) return {} as T;
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, 'base64').toString('utf8')
    : event.body;
  try {
    return JSON.parse(raw) as T;
  } catch {
    throw new SyntaxError('Invalid JSON body');
  }
}
