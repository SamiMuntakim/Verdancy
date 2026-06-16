// Gemini and the S3 presigner are mocked so these run offline and deterministically.
jest.mock('../src/lib/gemini', () => ({
  identify: jest.fn(),
  diagnose: jest.fn(),
}));
jest.mock('@aws-sdk/s3-request-presigner', () => ({
  getSignedUrl: jest.fn().mockResolvedValue('https://signed.example/url'),
}));

import { mockClient } from 'aws-sdk-client-mock';
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
  BatchWriteCommand,
} from '@aws-sdk/lib-dynamodb';
import { S3Client, DeleteObjectsCommand } from '@aws-sdk/client-s3';
import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyStructuredResultV2,
} from 'aws-lambda';
import { handler } from '../src/handlers/router';
import { identify, diagnose } from '../src/lib/gemini';

const ddbMock = mockClient(DynamoDBDocumentClient);
const s3Mock = mockClient(S3Client);
const identifyMock = identify as jest.Mock;
const diagnoseMock = diagnose as jest.Mock;

const SUB = 'me';

function condFail(): Error {
  const e = new Error('The conditional request failed');
  e.name = 'ConditionalCheckFailedException';
  return e;
}

interface EventOpts {
  routeKey: string;
  sub?: string | null;
  body?: unknown;
  pathParameters?: Record<string, string>;
  email?: string;
}

function makeEvent(opts: EventOpts): APIGatewayProxyEventV2WithJWTAuthorizer {
  const claims: Record<string, unknown> = {};
  if (opts.sub) claims.sub = opts.sub;
  if (opts.email) claims.email = opts.email;
  return {
    routeKey: opts.routeKey,
    rawPath: '/',
    headers: {},
    pathParameters: opts.pathParameters,
    isBase64Encoded: false,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    requestContext: {
      http: { method: opts.routeKey.split(' ')[0], path: opts.routeKey.split(' ')[1] },
      authorizer: { jwt: { claims, scopes: [] } },
    },
  } as unknown as APIGatewayProxyEventV2WithJWTAuthorizer;
}

async function run(opts: EventOpts): Promise<APIGatewayProxyStructuredResultV2> {
  return (await handler(makeEvent({ sub: SUB, ...opts }))) as APIGatewayProxyStructuredResultV2;
}

function bodyOf(res: APIGatewayProxyStructuredResultV2): Record<string, unknown> {
  return JSON.parse(res.body as string);
}

beforeAll(() => {
  process.env.TABLE_NAME = 'VerdancyData';
  process.env.USER_IMAGE_BUCKET = 'verdancy-user-images-test';
  process.env.FREE_AI_LIFETIME_LIMIT = '5';
  process.env.SUBSCRIBER_DAILY_AI_LIMIT = '50';
});

beforeEach(() => {
  ddbMock.reset();
  s3Mock.reset();
  identifyMock.mockReset();
  diagnoseMock.mockReset();
});

describe('identity', () => {
  test('401 when the JWT has no sub', async () => {
    const res = await run({ routeKey: 'GET /me/trees', sub: null });
    expect(res.statusCode).toBe(401);
  });
});

describe('POST /uploads — server mints keys under the caller prefix (invariant #7)', () => {
  test('plant: returns an image_ref under u/<sub>/ and a plantId', async () => {
    const res = await run({ routeKey: 'POST /uploads', body: { kind: 'plant' } });
    expect(res.statusCode).toBe(200);
    const out = bodyOf(res);
    expect(String(out.image_ref).startsWith(`u/${SUB}/p/`)).toBe(true);
    expect(out.upload_url).toBe('https://signed.example/url');
    expect(typeof out.plantId).toBe('string');
  });

  test('photo: 404 when the plant is not the caller’s', async () => {
    ddbMock.on(GetCommand).resolves({ Item: undefined });
    const res = await run({ routeKey: 'POST /uploads', body: { kind: 'photo', plantId: 'p1' } });
    expect(res.statusCode).toBe(404);
  });
});

describe('POST /plants — object-level authorization (invariant #2)', () => {
  test('403 when image_ref belongs to another user', async () => {
    const res = await run({
      routeKey: 'POST /plants',
      body: { image_ref: 'u/someone-else/p/p1/x.jpg', species: 'Monstera' },
    });
    expect(res.statusCode).toBe(403);
    expect(ddbMock.commandCalls(PutCommand)).toHaveLength(0);
  });

  test('happy path: seeds care, normalizes species, derives plantId from key', async () => {
    ddbMock.on(PutCommand).resolves({});
    const res = await run({
      routeKey: 'POST /plants',
      body: {
        image_ref: `u/${SUB}/p/plant-9/abc.jpg`,
        common_name: 'Monstera',
        species: 'Monstera Deliciosa, Variegata',
        water_cadence_days: 7,
        fertilize_cadence_days: 30,
      },
    });
    expect(res.statusCode).toBe(201);
    expect(bodyOf(res).plantId).toBe('plant-9');
    const item = ddbMock.commandCalls(PutCommand)[0].args[0].input.Item as Record<string, unknown>;
    expect(item.species).toBe('monstera deliciosa');
    expect((item.care as Record<string, { cadence_days: number }>).water.cadence_days).toBe(7);
  });
});

describe('GET /plants — fresh presigned download URLs', () => {
  test('returns each plant with a download_url', async () => {
    ddbMock.on(QueryCommand).resolves({
      Items: [{ PK: `USER#${SUB}`, SK: 'PLANT#p1', image_ref: `u/${SUB}/p/p1/a.jpg` }],
    });
    const res = await run({ routeKey: 'GET /plants' });
    expect(res.statusCode).toBe(200);
    const plants = bodyOf(res).plants as Array<Record<string, unknown>>;
    expect(plants[0].plantId).toBe('p1');
    expect(plants[0].download_url).toBe('https://signed.example/url');
  });
});

describe('POST /plants/{plantId}/care', () => {
  test('water: updates last_done_at via a conditional UpdateItem', async () => {
    ddbMock.on(UpdateCommand).resolves({});
    const res = await run({
      routeKey: 'POST /plants/{plantId}/care',
      pathParameters: { plantId: 'p1' },
      body: { type: 'water' },
    });
    expect(res.statusCode).toBe(200);
    const input = ddbMock.commandCalls(UpdateCommand)[0].args[0].input;
    expect(input.UpdateExpression).toContain('care.#t.last_done_at');
    expect(input.ExpressionAttributeNames?.['#t']).toBe('water');
    expect(input.ConditionExpression).toBe('attribute_exists(SK)');
  });

  test('404 when the plant is not the caller’s (conditional fails)', async () => {
    ddbMock.on(UpdateCommand).rejects(condFail());
    const res = await run({
      routeKey: 'POST /plants/{plantId}/care',
      pathParameters: { plantId: 'p1' },
      body: { type: 'water' },
    });
    expect(res.statusCode).toBe(404);
  });

  test('400 on an invalid care type', async () => {
    const res = await run({
      routeKey: 'POST /plants/{plantId}/care',
      pathParameters: { plantId: 'p1' },
      body: { type: 'sing' },
    });
    expect(res.statusCode).toBe(400);
  });
});

describe('DELETE /plants/{plantId} — cascade to S3 + records', () => {
  test('deletes the plant image, photo images, and items', async () => {
    ddbMock.on(GetCommand).resolves({
      Item: { PK: `USER#${SUB}`, SK: 'PLANT#p1', image_ref: `u/${SUB}/p/p1/a.jpg` },
    });
    ddbMock.on(QueryCommand).resolves({
      Items: [{ SK: 'PHOTO#p1#t1', image_ref: `u/${SUB}/p/p1/b.jpg` }],
    });
    ddbMock.on(BatchWriteCommand).resolves({});
    s3Mock.on(DeleteObjectsCommand).resolves({});

    const res = await run({
      routeKey: 'DELETE /plants/{plantId}',
      pathParameters: { plantId: 'p1' },
    });
    expect(res.statusCode).toBe(200);
    const del = s3Mock.commandCalls(DeleteObjectsCommand)[0].args[0].input;
    const keys = del.Delete?.Objects?.map((o) => o.Key);
    expect(keys).toEqual(expect.arrayContaining([`u/${SUB}/p/p1/a.jpg`, `u/${SUB}/p/p1/b.jpg`]));
    expect(ddbMock.commandCalls(BatchWriteCommand)).toHaveLength(1);
  });

  test('404 when not the caller’s plant — nothing deleted', async () => {
    ddbMock.on(GetCommand).resolves({ Item: undefined });
    const res = await run({
      routeKey: 'DELETE /plants/{plantId}',
      pathParameters: { plantId: 'p1' },
    });
    expect(res.statusCode).toBe(404);
    expect(s3Mock.commandCalls(DeleteObjectsCommand)).toHaveLength(0);
  });
});

describe('AI proxy — reserve quota BEFORE Gemini (invariant #3)', () => {
  test('blocked account → 403, Gemini not called', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { blocked: true } });
    const res = await run({ routeKey: 'POST /identify', body: { image: 'abc' } });
    expect(res.statusCode).toBe(403);
    expect(identifyMock).not.toHaveBeenCalled();
  });

  test('non-subscriber under free limit → 200, Gemini called', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { entitlement_active: false, free_ai_used: 0 } });
    ddbMock.on(UpdateCommand).resolves({});
    identifyMock.mockResolvedValue({ common_name: 'Monstera', confidence: 'High' });
    const res = await run({ routeKey: 'POST /identify', body: { image: 'abc' } });
    expect(res.statusCode).toBe(200);
    expect(identifyMock).toHaveBeenCalledTimes(1);
    const input = ddbMock.commandCalls(UpdateCommand)[0].args[0].input;
    expect(input.Key).toEqual({ PK: `USER#${SUB}`, SK: 'METADATA' });
    expect(input.ConditionExpression).toBe(
      'attribute_not_exists(free_ai_used) OR free_ai_used < :limit',
    );
  });

  test('non-subscriber over free limit → 402, Gemini NOT called', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { entitlement_active: false, free_ai_used: 5 } });
    ddbMock.on(UpdateCommand).rejects(condFail());
    const res = await run({ routeKey: 'POST /identify', body: { image: 'abc' } });
    expect(res.statusCode).toBe(402);
    expect(identifyMock).not.toHaveBeenCalled();
  });

  test('subscriber over daily cap → 429, Gemini NOT called, date-keyed quota item', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { entitlement_active: true } });
    ddbMock.on(UpdateCommand).rejects(condFail());
    const res = await run({ routeKey: 'POST /identify', body: { image: 'abc' } });
    expect(res.statusCode).toBe(429);
    expect(identifyMock).not.toHaveBeenCalled();
    const sk = ddbMock.commandCalls(UpdateCommand)[0].args[0].input.Key?.SK as string;
    expect(sk.startsWith('QUOTA#')).toBe(true);
  });

  test('diagnose returns the model’s ordered steps', async () => {
    ddbMock.on(GetCommand).resolves({ Item: { entitlement_active: true } });
    ddbMock.on(UpdateCommand).resolves({});
    diagnoseMock.mockResolvedValue({ issue: 'Root rot', steps: ['Stop watering', 'Repot'] });
    const res = await run({ routeKey: 'POST /diagnose', body: { image: 'abc' } });
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res).steps).toEqual(['Stop watering', 'Repot']);
  });
});

describe('POST /milestones — one atomic conditional write (invariant #5)', () => {
  test('first submit increments trees once', async () => {
    ddbMock.on(UpdateCommand).resolves({
      Attributes: { trees_pledged: 1, milestones: new Set(['first-plant']) },
    });
    const res = await run({ routeKey: 'POST /milestones', body: { milestoneId: 'first-plant' } });
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res).trees_pledged).toBe(1);
    expect(ddbMock.commandCalls(UpdateCommand)[0].args[0].input.ConditionExpression).toBe(
      'NOT contains(milestones, :mid)',
    );
  });

  test('duplicate submit is idempotent (+1 once)', async () => {
    ddbMock.on(UpdateCommand).rejects(condFail());
    ddbMock.on(GetCommand).resolves({
      Item: { trees_pledged: 1, milestones: new Set(['first-plant']) },
    });
    const res = await run({ routeKey: 'POST /milestones', body: { milestoneId: 'first-plant' } });
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res).trees_pledged).toBe(1);
  });

  test('400 when milestoneId missing', async () => {
    const res = await run({ routeKey: 'POST /milestones', body: {} });
    expect(res.statusCode).toBe(400);
  });
});

describe('GET /me/trees & POST /users', () => {
  test('/me/trees returns the pledge count and milestone array', async () => {
    ddbMock.on(GetCommand).resolves({
      Item: { trees_pledged: 3, milestones: new Set(['a', 'b']) },
    });
    const res = await run({ routeKey: 'GET /me/trees' });
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res).trees_pledged).toBe(3);
    expect((bodyOf(res).milestones as string[]).sort()).toEqual(['a', 'b']);
  });

  test('/users upserts using the email claim (not the body)', async () => {
    ddbMock.on(UpdateCommand).resolves({});
    const res = await run({
      routeKey: 'POST /users',
      email: 'me@example.com',
      body: { email: 'evil@x' },
    });
    expect(res.statusCode).toBe(200);
    const input = ddbMock.commandCalls(UpdateCommand)[0].args[0].input;
    expect(input.ExpressionAttributeValues?.[':email']).toBe('me@example.com');
  });
});
