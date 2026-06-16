import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { VerdancyStack } from '../lib/verdancy-stack';
import { readAuthConfig, type AuthConfig } from '../lib/config';

const baseAuth: AuthConfig = {
  callbackUrls: ['verdancy://auth/callback'],
  logoutUrls: ['verdancy://auth/logout'],
};

function synth(auth: AuthConfig, retainResources = false): Template {
  const app = new cdk.App();
  const stack = new VerdancyStack(app, 'TestStack', {
    env: { account: '123456789012', region: 'us-east-1' },
    auth,
    retainResources,
  });
  return Template.fromStack(stack);
}

describe('Cognito user pool (security baseline)', () => {
  const template = synth(baseAuth);

  test('creates exactly one user pool', () => {
    template.resourceCountIs('AWS::Cognito::UserPool', 1);
  });

  test('enforces a strong password policy', () => {
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      Policies: {
        PasswordPolicy: {
          MinimumLength: 12,
          RequireLowercase: true,
          RequireUppercase: true,
          RequireNumbers: true,
          RequireSymbols: true,
        },
      },
    });
  });

  test('auto-verifies email and requires it', () => {
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      AutoVerifiedAttributes: ['email'],
      Schema: Match.arrayWith([Match.objectLike({ Name: 'email', Required: true, Mutable: true })]),
    });
  });

  test('user pool is destroyable by default (dev posture)', () => {
    template.hasResource('AWS::Cognito::UserPool', { DeletionPolicy: 'Delete' });
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      DeletionProtection: 'INACTIVE',
    });
  });
});

describe('Production retention (retainResources=true)', () => {
  const template = synth(baseAuth, true);

  test('retains and deletion-protects the user pool', () => {
    template.hasResource('AWS::Cognito::UserPool', { DeletionPolicy: 'Retain' });
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      DeletionProtection: 'ACTIVE',
    });
  });
});

describe('App client (public mobile client)', () => {
  const template = synth(baseAuth);

  test('has no client secret and uses SRP', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      GenerateSecret: false,
      ExplicitAuthFlows: Match.arrayWith(['ALLOW_USER_SRP_AUTH']),
      PreventUserExistenceErrors: 'ENABLED',
    });
  });

  test('sets sensible token validity (1h access/id, 30d refresh)', () => {
    // CDK always renders token validity in minutes: 1h = 60, 30d = 43200.
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      AccessTokenValidity: 60,
      IdTokenValidity: 60,
      RefreshTokenValidity: 43200,
      TokenValidityUnits: {
        AccessToken: 'minutes',
        IdToken: 'minutes',
        RefreshToken: 'minutes',
      },
    });
  });
});

describe('Email-only configuration (no federation)', () => {
  const template = synth(baseAuth);

  test('creates no identity providers', () => {
    template.resourceCountIs('AWS::Cognito::UserPoolIdentityProvider', 0);
  });

  test('creates no hosted domain', () => {
    template.resourceCountIs('AWS::Cognito::UserPoolDomain', 0);
  });

  test('app client supports only the Cognito provider', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      SupportedIdentityProviders: ['COGNITO'],
    });
  });

  // Regression guard: a client flagged OAuth-enabled with zero flows is rejected
  // by Cognito at deploy ("AllowedOAuthFlows and AllowedOAuthScopes are required").
  // Email-only must disable OAuth entirely.
  test('disables hosted-UI OAuth entirely', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      AllowedOAuthFlowsUserPoolClient: false,
      AllowedOAuthFlows: Match.absent(),
      AllowedOAuthScopes: Match.absent(),
    });
  });
});

describe('Federation enabled (Apple + Google)', () => {
  const federatedAuth: AuthConfig = {
    ...baseAuth,
    domainPrefix: 'verdancy-auth-test',
    apple: {
      servicesId: 'com.verdancy.signin',
      teamId: 'ABCDE12345',
      keyId: 'KEY1234567',
      privateKeySecretName: 'verdancy/apple-signin-key',
    },
    google: {
      clientId: '123-abc.apps.googleusercontent.com',
      clientSecretName: 'verdancy/google-oauth-secret',
    },
  };
  const template = synth(federatedAuth);

  test('creates an Apple and a Google identity provider', () => {
    template.resourceCountIs('AWS::Cognito::UserPoolIdentityProvider', 2);
    template.hasResourceProperties('AWS::Cognito::UserPoolIdentityProvider', {
      ProviderType: 'SignInWithApple',
      ProviderName: 'SignInWithApple',
    });
    template.hasResourceProperties('AWS::Cognito::UserPoolIdentityProvider', {
      ProviderType: 'Google',
      ProviderName: 'Google',
    });
  });

  test('creates a hosted domain with the configured prefix', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolDomain', {
      Domain: 'verdancy-auth-test',
    });
  });

  test('app client supports Cognito, Apple, and Google with the auth-code flow', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      SupportedIdentityProviders: Match.arrayWith(['COGNITO', 'SignInWithApple', 'Google']),
      CallbackURLs: ['verdancy://auth/callback'],
      AllowedOAuthFlowsUserPoolClient: true,
      AllowedOAuthFlows: ['code'],
      AllowedOAuthScopes: Match.arrayWith(['openid', 'email', 'profile']),
    });
  });

  test('Apple private key is a Secrets Manager dynamic reference, not a literal', () => {
    const idps = template.findResources('AWS::Cognito::UserPoolIdentityProvider', {
      Properties: { ProviderType: 'SignInWithApple' },
    });
    const apple = Object.values(idps)[0] as {
      Properties: { ProviderDetails: { private_key: string } };
    };
    expect(apple.Properties.ProviderDetails.private_key).toContain(
      '{{resolve:secretsmanager:verdancy/apple-signin-key',
    );
  });
});

describe('Config reader (readAuthConfig)', () => {
  test('returns email-only config when no IdP context is set', () => {
    const cfg = readAuthConfig(new cdk.App());
    expect(cfg.apple).toBeUndefined();
    expect(cfg.google).toBeUndefined();
    expect(cfg.callbackUrls.length).toBeGreaterThan(0);
  });

  test('throws on partial Apple config', () => {
    const app = new cdk.App({ context: { 'apple:servicesId': 'a' } });
    expect(() => readAuthConfig(app)).toThrow(/Incomplete Apple config/);
  });

  test('throws when federation is enabled without a domain prefix', () => {
    const app = new cdk.App({
      context: {
        'apple:servicesId': 'a',
        'apple:teamId': 'b',
        'apple:keyId': 'c',
        'apple:privateKeySecretName': 'd',
      },
    });
    expect(() => readAuthConfig(app)).toThrow(/domainPrefix is required/);
  });
});
