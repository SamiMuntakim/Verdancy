import { mockClient } from 'aws-sdk-client-mock';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import type {
  CreateAuthChallengeTriggerEvent,
  DefineAuthChallengeTriggerEvent,
  VerifyAuthChallengeResponseTriggerEvent,
} from 'aws-lambda';
import { handler } from '../src/handlers/auth-challenge';
import { _clearSecretCacheForTest } from '../src/lib/secrets';

const smMock = mockClient(SecretsManagerClient);
const BROKER_SECRET = 'broker-secret-value';

beforeAll(() => {
  process.env.AUTH_BROKER_SECRET_ARN = 'arn:aws:secretsmanager:us-west-1:123:secret:broker';
});

beforeEach(() => {
  smMock.reset();
  _clearSecretCacheForTest();
  smMock.on(GetSecretValueCommand).resolves({ SecretString: BROKER_SECRET });
});

function defineEvent(
  session: Array<{ challengeName: string; challengeResult: boolean }>,
): DefineAuthChallengeTriggerEvent {
  return {
    triggerSource: 'DefineAuthChallenge_Authentication',
    request: { session, userAttributes: {}, userNotFound: false },
    response: {},
  } as unknown as DefineAuthChallengeTriggerEvent;
}

function verifyEvent(challengeAnswer: string): VerifyAuthChallengeResponseTriggerEvent {
  return {
    triggerSource: 'VerifyAuthChallengeResponse_Authentication',
    request: { privateChallengeParameters: {}, challengeAnswer, userAttributes: {} },
    response: {},
  } as unknown as VerifyAuthChallengeResponseTriggerEvent;
}

describe('DefineAuthChallenge', () => {
  test('issues the custom challenge on the first step', async () => {
    const res = (await handler(defineEvent([]))) as DefineAuthChallengeTriggerEvent;
    expect(res.response.challengeName).toBe('CUSTOM_CHALLENGE');
    expect(res.response.issueTokens).toBe(false);
    expect(res.response.failAuthentication).toBe(false);
  });

  test('issues tokens after the challenge is answered correctly', async () => {
    const res = (await handler(
      defineEvent([{ challengeName: 'CUSTOM_CHALLENGE', challengeResult: true }]),
    )) as DefineAuthChallengeTriggerEvent;
    expect(res.response.issueTokens).toBe(true);
    expect(res.response.failAuthentication).toBe(false);
  });

  test('fails authentication on a wrong answer', async () => {
    const res = (await handler(
      defineEvent([{ challengeName: 'CUSTOM_CHALLENGE', challengeResult: false }]),
    )) as DefineAuthChallengeTriggerEvent;
    expect(res.response.issueTokens).toBe(false);
    expect(res.response.failAuthentication).toBe(true);
  });
});

describe('CreateAuthChallenge', () => {
  test('exposes no secret material in the challenge parameters', async () => {
    const event = {
      triggerSource: 'CreateAuthChallenge_Authentication',
      request: { challengeName: 'CUSTOM_CHALLENGE', userAttributes: {}, session: [] },
      response: {},
    } as unknown as CreateAuthChallengeTriggerEvent;
    const res = (await handler(event)) as CreateAuthChallengeTriggerEvent;
    expect(res.response.publicChallengeParameters).toEqual({});
    expect(res.response.privateChallengeParameters).toEqual({});
    expect(res.response.challengeMetadata).toBe('BACKEND_BROKERED');
  });
});

describe('VerifyAuthChallengeResponse', () => {
  test('accepts the exact broker secret', async () => {
    const res = (await handler(
      verifyEvent(BROKER_SECRET),
    )) as VerifyAuthChallengeResponseTriggerEvent;
    expect(res.response.answerCorrect).toBe(true);
  });

  test('rejects any other answer', async () => {
    const res = (await handler(
      verifyEvent('not-the-secret'),
    )) as VerifyAuthChallengeResponseTriggerEvent;
    expect(res.response.answerCorrect).toBe(false);
  });

  test('fails closed if the secret cannot be loaded', async () => {
    smMock.on(GetSecretValueCommand).rejects(new Error('boom'));
    const res = (await handler(
      verifyEvent(BROKER_SECRET),
    )) as VerifyAuthChallengeResponseTriggerEvent;
    expect(res.response.answerCorrect).toBe(false);
  });
});
