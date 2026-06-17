jest.mock('../src/lib/gemini', () => ({ generateBuddyImage: jest.fn() }));

import { mockClient } from 'aws-sdk-client-mock';
import {
  DynamoDBDocumentClient,
  QueryCommand,
  GetCommand,
  PutCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { PNG } from 'pngjs';
import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyStructuredResultV2,
} from 'aws-lambda';
import { handler } from '../src/handlers/buddy';
import { generateBuddyImage } from '../src/lib/gemini';

const ddbMock = mockClient(DynamoDBDocumentClient);
const s3Mock = mockClient(S3Client);
const genMock = generateBuddyImage as jest.Mock;

const SUB = 'me';
const SPECIES = 'monstera deliciosa';

function condFail(): Error {
  const e = new Error('conditional failed');
  e.name = 'ConditionalCheckFailedException';
  return e;
}

function smallPng(): Buffer {
  const png = new PNG({ width: 4, height: 4 });
  for (let i = 0; i < png.data.length; i += 4) {
    png.data[i] = 80;
    png.data[i + 1] = 150;
    png.data[i + 2] = 80;
    png.data[i + 3] = 255;
  }
  return PNG.sync.write(png);
}

function run(body: unknown): Promise<APIGatewayProxyStructuredResultV2> {
  const event = {
    routeKey: 'POST /buddy',
    headers: {},
    isBase64Encoded: false,
    body: body === undefined ? undefined : JSON.stringify(body),
    requestContext: {
      http: { method: 'POST', path: '/buddy' },
      authorizer: { jwt: { claims: { sub: SUB }, scopes: [] } },
    },
  } as unknown as APIGatewayProxyEventV2WithJWTAuthorizer;
  return handler(event) as Promise<APIGatewayProxyStructuredResultV2>;
}

const bodyOf = (r: APIGatewayProxyStructuredResultV2) => JSON.parse(r.body as string);

beforeAll(() => {
  process.env.TABLE_NAME = 'VerdancyData';
  process.env.SPRITE_BUCKET = 'verdancy-sprites-test';
  process.env.SPRITE_CDN_BASE = 'https://cdn.example';
});

beforeEach(() => {
  ddbMock.reset();
  s3Mock.reset();
  genMock.mockReset();
});

test('400 when species is missing', async () => {
  const res = await run({});
  expect(res.statusCode).toBe(400);
});

test('403 when the caller has no plant of that species', async () => {
  ddbMock.on(QueryCommand).resolves({ Items: [] });
  const res = await run({ species: SPECIES });
  expect(res.statusCode).toBe(403);
  expect(genMock).not.toHaveBeenCalled();
});

test('200 cache hit returns the stored sprite (no generation)', async () => {
  ddbMock.on(QueryCommand).resolves({ Items: [{ species: SPECIES }] });
  ddbMock.on(GetCommand).resolves({
    Item: { status: 'ready', sprite_url: 'https://cdn.example/sprites/x/v1.png', style_version: 1 },
  });
  const res = await run({ species: SPECIES });
  expect(res.statusCode).toBe(200);
  expect(bodyOf(res).sprite_url).toContain('/sprites/');
  expect(genMock).not.toHaveBeenCalled();
});

test('201 generates → processes → uploads → finalizes', async () => {
  ddbMock.on(QueryCommand).resolves({ Items: [{ species: SPECIES }] });
  ddbMock.on(GetCommand).resolves({ Item: undefined });
  ddbMock.on(PutCommand).resolves({}); // claim
  ddbMock.on(UpdateCommand).resolves({}); // finalize
  s3Mock.on(PutObjectCommand).resolves({});
  genMock.mockResolvedValue({ data: smallPng(), mimeType: 'image/png' });

  const res = await run({ species: SPECIES });
  expect(res.statusCode).toBe(201);
  expect(bodyOf(res).status).toBe('ready');
  expect(bodyOf(res).sprite_url).toContain('/sprites/');
  expect(s3Mock.commandCalls(PutObjectCommand)).toHaveLength(1);
  expect(genMock).toHaveBeenCalledTimes(1);
});

test('202 when another caller holds the generation claim', async () => {
  ddbMock.on(QueryCommand).resolves({ Items: [{ species: SPECIES }] });
  ddbMock
    .on(GetCommand)
    .resolvesOnce({ Item: undefined })
    .resolves({ Item: { status: 'pending' } });
  ddbMock.on(PutCommand).rejects(condFail()); // lost the claim race
  const res = await run({ species: SPECIES });
  expect(res.statusCode).toBe(202);
  expect(bodyOf(res).status).toBe('pending');
  expect(genMock).not.toHaveBeenCalled();
});
