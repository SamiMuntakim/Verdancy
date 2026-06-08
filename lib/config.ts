import type { App } from 'aws-cdk-lib';

/**
 * Federated identity-provider configuration, read from CDK context at synth/deploy
 * time. Non-secret IDs are supplied as plain context values; the secret material
 * (Apple private key, Google client secret) is referenced **by name** from AWS
 * Secrets Manager and never appears in context, git, or the synthesized template.
 *
 * Provide values either in a (gitignored) `cdk.context.json` or on the CLI, e.g.:
 *   npx cdk synth \
 *     -c apple:servicesId=com.verdancy.signin \
 *     -c apple:teamId=ABCDE12345 \
 *     -c apple:keyId=KEY1234567 \
 *     -c apple:privateKeySecretName=verdancy/apple-signin-key \
 *     -c google:clientId=...apps.googleusercontent.com \
 *     -c google:clientSecretName=verdancy/google-oauth-secret \
 *     -c cognito:domainPrefix=verdancy-auth-prod
 *
 * Federation is opt-in: with no Apple/Google context, the stack synths and deploys
 * an email/password-only user pool (still a valid configuration). Apple and Google
 * each switch on once their full set of values is present.
 */
export interface AppleConfig {
  /** Apple Services ID (the "client id" for Sign in with Apple). */
  readonly servicesId: string;
  /** Apple Developer Team ID. */
  readonly teamId: string;
  /** Key ID of the Sign in with Apple private key (.p8). */
  readonly keyId: string;
  /** Secrets Manager secret *name* holding the .p8 private key contents. */
  readonly privateKeySecretName: string;
}

export interface GoogleConfig {
  /** Google OAuth client ID. */
  readonly clientId: string;
  /** Secrets Manager secret *name* holding the Google OAuth client secret. */
  readonly clientSecretName: string;
}

export interface AuthConfig {
  readonly apple?: AppleConfig;
  readonly google?: GoogleConfig;
  /**
   * Globally-unique Cognito hosted-domain prefix. Required when any federated
   * IdP is enabled, because Apple/Google federation needs the Cognito OAuth2
   * endpoints (`/oauth2/idpresponse`) even though the iOS app drives sign-in
   * natively rather than via the Hosted UI.
   */
  readonly domainPrefix?: string;
  /** OAuth redirect URIs registered on the app client (custom URL scheme for the native flow). */
  readonly callbackUrls: string[];
  /** OAuth sign-out URIs registered on the app client. */
  readonly logoutUrls: string[];
}

function ctx(app: App, key: string): string | undefined {
  const value = app.node.tryGetContext(key);
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined;
}

function ctxList(app: App, key: string, fallback: string[]): string[] {
  const raw = ctx(app, key);
  if (!raw) return fallback;
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export function readAuthConfig(app: App): AuthConfig {
  // Apple is enabled only when the full set of values is present.
  const appleServicesId = ctx(app, 'apple:servicesId');
  const appleTeamId = ctx(app, 'apple:teamId');
  const appleKeyId = ctx(app, 'apple:keyId');
  const applePrivateKeySecretName = ctx(app, 'apple:privateKeySecretName');
  const appleParts = [appleServicesId, appleTeamId, appleKeyId, applePrivateKeySecretName];
  const appleProvided = appleParts.some((v) => v !== undefined);
  let apple: AppleConfig | undefined;
  if (appleProvided) {
    if (appleParts.some((v) => v === undefined)) {
      throw new Error(
        'Incomplete Apple config: provide all of apple:servicesId, apple:teamId, ' +
          'apple:keyId, apple:privateKeySecretName (or none to disable Apple sign-in).',
      );
    }
    apple = {
      servicesId: appleServicesId!,
      teamId: appleTeamId!,
      keyId: appleKeyId!,
      privateKeySecretName: applePrivateKeySecretName!,
    };
  }

  // Google is enabled only when both clientId and the secret name are present.
  const googleClientId = ctx(app, 'google:clientId');
  const googleClientSecretName = ctx(app, 'google:clientSecretName');
  const googleProvided = googleClientId !== undefined || googleClientSecretName !== undefined;
  let google: GoogleConfig | undefined;
  if (googleProvided) {
    if (googleClientId === undefined || googleClientSecretName === undefined) {
      throw new Error(
        'Incomplete Google config: provide both google:clientId and ' +
          'google:clientSecretName (or neither to disable Google sign-in).',
      );
    }
    google = { clientId: googleClientId, clientSecretName: googleClientSecretName };
  }

  const domainPrefix = ctx(app, 'cognito:domainPrefix');
  if ((apple || google) && !domainPrefix) {
    throw new Error(
      'cognito:domainPrefix is required when Apple or Google sign-in is enabled ' +
        '(federation needs the Cognito OAuth2 endpoints). It must be globally unique.',
    );
  }

  return {
    apple,
    google,
    domainPrefix,
    callbackUrls: ctxList(app, 'cognito:callbackUrls', ['verdancy://auth/callback']),
    logoutUrls: ctxList(app, 'cognito:logoutUrls', ['verdancy://auth/logout']),
  };
}
