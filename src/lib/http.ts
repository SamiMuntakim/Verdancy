import type { APIGatewayProxyStructuredResultV2 } from 'aws-lambda';

/**
 * Build a clean JSON HTTP-API response. Statuses are constrained to the set the
 * PRD allows: 200 / 400 / 401 / 402 / 403 / 404 / 429 / 500 (plus 501 for the
 * not-yet-implemented Phase 2 shells).
 */
export function json(statusCode: number, body: unknown): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  };
}
