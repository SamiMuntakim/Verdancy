import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { json } from '../lib/http';

/**
 * Main router Lambda — the AI proxy + data CRUD for every Cognito-authenticated
 * route. Phase 2: a shell that returns 501 for all routes. Phase 3 implements the
 * real logic (entitlement/quota, presigned uploads, CRUD, milestones, …), deriving
 * identity ONLY from the verified JWT `sub` (never the body), per the hard invariants.
 */
export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  const route = `${event.requestContext.http.method} ${event.requestContext.http.path}`;
  return json(501, { error: 'Not Implemented', route });
};
