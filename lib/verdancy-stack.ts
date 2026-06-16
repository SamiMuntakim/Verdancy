import * as cdk from 'aws-cdk-lib';
import { Duration, RemovalPolicy, SecretValue } from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import type { Construct } from 'constructs';
import type { AuthConfig } from './config';

export interface VerdancyStackProps extends cdk.StackProps {
  /** Federated identity-provider + Cognito-domain configuration (see lib/config.ts). */
  readonly auth: AuthConfig;
  /**
   * Production posture: when true, the user pool is deletion-protected and
   * retained on stack delete. Default false (dev) so failed deploys roll back
   * cleanly instead of orphaning a protected pool. Set `-c retainResources=true`
   * for production. Flip this on before there are real users.
   */
  readonly retainResources?: boolean;
}

/**
 * The single Verdancy backend stack.
 *
 * Phase 1 (current): Amazon Cognito user pool with native Sign in with Apple
 * (federated) + Google + email/password, plus the app client the iOS app uses.
 * DynamoDB, S3, the HTTP API, and the Lambdas arrive in later phases.
 */
export class VerdancyStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: VerdancyStackProps) {
    super(scope, id, props);

    const { auth } = props;
    const retain = props.retainResources ?? false;

    // ---------------------------------------------------------------------
    // User pool — email/password baseline with a hardened security posture.
    // ---------------------------------------------------------------------
    const userPool = new cognito.UserPool(this, 'UserPool', {
      userPoolName: 'verdancy-users',
      selfSignUpEnabled: true,
      signInAliases: { email: true },
      signInCaseSensitive: false,
      autoVerify: { email: true },
      keepOriginal: { email: true },
      standardAttributes: {
        email: { required: true, mutable: true },
      },
      passwordPolicy: {
        minLength: 12,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true,
        tempPasswordValidity: Duration.days(3),
      },
      mfa: cognito.Mfa.OFF,
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      // In production a user pool holds real accounts: protect it. In dev, allow
      // clean rollback/teardown so a failed deploy doesn't orphan a locked pool.
      deletionProtection: retain,
      removalPolicy: retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    // ---------------------------------------------------------------------
    // Federated identity providers (opt-in via context — see lib/config.ts).
    // Secret material is pulled from Secrets Manager by name; nothing secret
    // is hardcoded or rendered into the template.
    // ---------------------------------------------------------------------
    const identityProviders: cognito.UserPoolClientIdentityProvider[] = [
      cognito.UserPoolClientIdentityProvider.COGNITO,
    ];
    const idpConstructs: cognito.IUserPoolIdentityProvider[] = [];

    if (auth.apple) {
      const appleIdp = new cognito.UserPoolIdentityProviderApple(this, 'AppleIdp', {
        userPool,
        clientId: auth.apple.servicesId,
        teamId: auth.apple.teamId,
        keyId: auth.apple.keyId,
        privateKeyValue: SecretValue.secretsManager(auth.apple.privateKeySecretName),
        scopes: ['name', 'email'],
        attributeMapping: {
          email: cognito.ProviderAttribute.APPLE_EMAIL,
        },
      });
      identityProviders.push(cognito.UserPoolClientIdentityProvider.APPLE);
      idpConstructs.push(appleIdp);
    }

    if (auth.google) {
      const googleIdp = new cognito.UserPoolIdentityProviderGoogle(this, 'GoogleIdp', {
        userPool,
        clientId: auth.google.clientId,
        clientSecretValue: SecretValue.secretsManager(auth.google.clientSecretName),
        scopes: ['openid', 'email', 'profile'],
        attributeMapping: {
          email: cognito.ProviderAttribute.GOOGLE_EMAIL,
        },
      });
      identityProviders.push(cognito.UserPoolClientIdentityProvider.GOOGLE);
      idpConstructs.push(googleIdp);
    }

    const federationEnabled = idpConstructs.length > 0;

    // A Cognito hosted domain is required for the OAuth2 endpoints that the
    // Apple/Google federation uses (the app still signs in natively, but the
    // IdP callback lands on `/oauth2/idpresponse`). Email-only needs no domain.
    if (federationEnabled) {
      const domain = userPool.addDomain('HostedDomain', {
        cognitoDomain: { domainPrefix: auth.domainPrefix! },
      });
      new cdk.CfnOutput(this, 'CognitoDomainBaseUrl', {
        value: domain.baseUrl(),
        description: 'Base URL of the Cognito hosted domain (OAuth2 / idpresponse endpoints).',
      });
    }

    // ---------------------------------------------------------------------
    // App client — public mobile client (no secret). Email/password uses SRP;
    // federated sign-in uses the authorization-code grant against the domain.
    // ---------------------------------------------------------------------
    // Hosted-UI OAuth is only used by federated sign-in (the IdP callback flow).
    // Email/password uses SRP and needs no OAuth flows — so disable OAuth entirely
    // when there's no federation. (Leaving OAuth "enabled" with zero flows is what
    // Cognito rejects: "AllowedOAuthFlows and AllowedOAuthScopes are required".)
    const oAuthSettings: Pick<cognito.UserPoolClientOptions, 'oAuth' | 'disableOAuth'> =
      federationEnabled
        ? {
            oAuth: {
              flows: { authorizationCodeGrant: true },
              scopes: [
                cognito.OAuthScope.OPENID,
                cognito.OAuthScope.EMAIL,
                cognito.OAuthScope.PROFILE,
              ],
              callbackUrls: auth.callbackUrls,
              logoutUrls: auth.logoutUrls,
            },
          }
        : { disableOAuth: true };

    const client = userPool.addClient('IosAppClient', {
      userPoolClientName: 'verdancy-ios',
      generateSecret: false,
      authFlows: {
        userSrp: true,
      },
      supportedIdentityProviders: identityProviders,
      preventUserExistenceErrors: true,
      enableTokenRevocation: true,
      accessTokenValidity: Duration.hours(1),
      idTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(30),
      ...oAuthSettings,
    });

    // The client references the IdPs in supportedIdentityProviders, so it must
    // be created after them.
    for (const idp of idpConstructs) {
      client.node.addDependency(idp);
    }

    // ---------------------------------------------------------------------
    // Outputs the iOS app + RevenueCat config need.
    // ---------------------------------------------------------------------
    new cdk.CfnOutput(this, 'UserPoolId', {
      value: userPool.userPoolId,
      description: 'Cognito User Pool ID.',
    });
    new cdk.CfnOutput(this, 'UserPoolClientId', {
      value: client.userPoolClientId,
      description: 'Cognito User Pool app client ID (iOS).',
    });
    new cdk.CfnOutput(this, 'Region', {
      value: this.region,
      description: 'Deployment region.',
    });
    new cdk.CfnOutput(this, 'EnabledIdentityProviders', {
      value: identityProviders.map((p) => p.name).join(', '),
      description: 'Identity providers wired into the app client.',
    });
  }
}
