import { timingSafeEqual } from 'node:crypto';
import type {
  CreateAuthChallengeTriggerEvent,
  DefineAuthChallengeTriggerEvent,
  VerifyAuthChallengeResponseTriggerEvent,
} from 'aws-lambda';
import { requireEnv } from '../lib/env';
import { getSecretString } from '../lib/secrets';

/**
 * Cognito custom-auth triggers for the native-federation flow, all three in one
 * Lambda (dispatched by `triggerSource`). The challenge is deliberately trivial:
 * the ONLY valid answer is the broker secret, which only our `/auth/*` Lambda
 * knows. So these triggers fire only for CUSTOM_AUTH and never affect SRP or
 * hosted-UI sign-in, and a client that calls CUSTOM_AUTH directly can't pass the
 * challenge.
 */
const CUSTOM_CHALLENGE = 'CUSTOM_CHALLENGE';

type TriggerEvent =
  | DefineAuthChallengeTriggerEvent
  | CreateAuthChallengeTriggerEvent
  | VerifyAuthChallengeResponseTriggerEvent;

export const handler = async (event: TriggerEvent): Promise<TriggerEvent> => {
  switch (event.triggerSource) {
    case 'DefineAuthChallenge_Authentication':
      return defineAuthChallenge(event as DefineAuthChallengeTriggerEvent);
    case 'CreateAuthChallenge_Authentication':
      return createAuthChallenge(event as CreateAuthChallengeTriggerEvent);
    case 'VerifyAuthChallengeResponse_Authentication':
      return verifyAuthChallenge(event as VerifyAuthChallengeResponseTriggerEvent);
    default:
      return event;
  }
};

function defineAuthChallenge(
  event: DefineAuthChallengeTriggerEvent,
): DefineAuthChallengeTriggerEvent {
  const session = event.request.session ?? [];
  if (session.length === 0) {
    // First step: present our single custom challenge.
    event.response.challengeName = CUSTOM_CHALLENGE;
    event.response.issueTokens = false;
    event.response.failAuthentication = false;
  } else if (
    session.length === 1 &&
    session[0].challengeName === CUSTOM_CHALLENGE &&
    session[0].challengeResult === true
  ) {
    // Challenge passed: issue tokens.
    event.response.issueTokens = true;
    event.response.failAuthentication = false;
  } else {
    // Wrong answer or an unexpected extra round: fail closed.
    event.response.issueTokens = false;
    event.response.failAuthentication = true;
  }
  return event;
}

function createAuthChallenge(
  event: CreateAuthChallengeTriggerEvent,
): CreateAuthChallengeTriggerEvent {
  if (event.request.challengeName === CUSTOM_CHALLENGE) {
    // Nothing to hand back to the client — the answer is the out-of-band broker
    // secret, never anything derived from these parameters.
    event.response.publicChallengeParameters = {};
    event.response.privateChallengeParameters = {};
    event.response.challengeMetadata = 'BACKEND_BROKERED';
  }
  return event;
}

async function verifyAuthChallenge(
  event: VerifyAuthChallengeResponseTriggerEvent,
): Promise<VerifyAuthChallengeResponseTriggerEvent> {
  const provided = event.request.challengeAnswer ?? '';
  let expected: string;
  try {
    expected = await getSecretString(requireEnv('AUTH_BROKER_SECRET_ARN'));
  } catch {
    // Never approve if we can't load the secret.
    event.response.answerCorrect = false;
    return event;
  }
  event.response.answerCorrect = constantTimeEqual(provided, expected);
  return event;
}

/** Constant-time compare that first rejects a length mismatch. */
function constantTimeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}
