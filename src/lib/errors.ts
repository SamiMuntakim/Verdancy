import { json } from './http';
import type { APIGatewayProxyStructuredResultV2 } from 'aws-lambda';

/**
 * A handler-level error carrying the HTTP status to return. Statuses are limited
 * to the PRD's allowed set: 400 / 401 / 402 / 403 / 404 / 429 / 500.
 */
export class ApiError extends Error {
  constructor(
    readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

/**
 * Map any thrown value to a clean JSON response. Known ApiErrors surface their
 * status + message; everything else becomes a 500 with a generic message (never
 * leak internals, secrets, or PII).
 */
export function toErrorResponse(err: unknown): APIGatewayProxyStructuredResultV2 {
  if (err instanceof ApiError) {
    return json(err.statusCode, { error: err.message });
  }
  // Generic log only — no event bodies, tokens, secrets, or images.
  console.error('Unhandled error', err instanceof Error ? err.name : typeof err);
  return json(500, { error: 'Internal Server Error' });
}
