import * as path from 'node:path';
import * as cdk from 'aws-cdk-lib';
import { Duration, RemovalPolicy, SecretValue } from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { HttpApi, HttpMethod, HttpNoneAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpUserPoolAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
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
 * Phase 1: Amazon Cognito user pool (native Sign in with Apple + Google + email)
 *   and the app client the iOS app uses.
 * Phase 2 (current): DynamoDB single table, private S3 image bucket, the HTTP API
 *   with a Cognito JWT authorizer on every route except the secret-verified
 *   RevenueCat webhook, and the router + webhook Lambdas (501 shells for now).
 * Phase 3 fills in the handler logic.
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

    // =====================================================================
    // Phase 2 — Data + storage + API shells
    // =====================================================================

    // ---------------------------------------------------------------------
    // DynamoDB — single table `VerdancyData`, on-demand, NO GSIs. TTL on
    // `expires_at` drives the daily-quota item's auto-expiry.
    // ---------------------------------------------------------------------
    const table = new dynamodb.Table(this, 'DataTable', {
      tableName: 'VerdancyData',
      partitionKey: { name: 'PK', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'SK', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'expires_at',
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      deletionProtection: retain,
      removalPolicy: retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    // ---------------------------------------------------------------------
    // S3 — one private bucket for user images. Block Public Access ON, TLS
    // enforced via bucket policy, accessed only through presigned URLs.
    // Bytes never pass through Lambda (hard invariant #6). Intelligent-Tiering
    // keeps cold-object cost down.
    // ---------------------------------------------------------------------
    const imageBucket = new s3.Bucket(this, 'UserImages', {
      bucketName: `verdancy-user-images-${this.account}-${this.region}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: false,
      lifecycleRules: [
        {
          id: 'intelligent-tiering',
          transitions: [
            {
              storageClass: s3.StorageClass.INTELLIGENT_TIERING,
              transitionAfter: Duration.days(0),
            },
          ],
        },
      ],
      autoDeleteObjects: !retain,
      removalPolicy: retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    // ---------------------------------------------------------------------
    // Secrets — the RevenueCat shared webhook secret. CDK generates the value;
    // fetch it after deploy and paste the same value into the RevenueCat
    // dashboard. (Gemini key arrives in Phase 3.)
    // ---------------------------------------------------------------------
    const webhookSecret = new secretsmanager.Secret(this, 'RevenueCatWebhookSecret', {
      secretName: 'verdancy/revenuecat-webhook-secret',
      description:
        'Shared secret RevenueCat sends in the Authorization header; also set this in RevenueCat.',
      generateSecretString: { passwordLength: 40, excludePunctuation: true },
      removalPolicy: retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    // ---------------------------------------------------------------------
    // Lambdas — Node.js 20.x, arm64. Phase 2 ships 501 shells; IAM grants for
    // the table/bucket land in Phase 3 when the router actually uses them
    // (least privilege). The webhook only needs to read its secret.
    // ---------------------------------------------------------------------
    const handlersDir = path.join(__dirname, '..', 'src', 'handlers');
    const commonFnProps = {
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler',
      bundling: {
        // AWS SDK v3 is provided by the Node 20 runtime — don't bundle it.
        externalModules: ['@aws-sdk/*'],
        minify: true,
        sourceMap: true,
        target: 'node20',
      },
    };

    const routerFn = new NodejsFunction(this, 'RouterFn', {
      ...commonFnProps,
      functionName: 'verdancy-router',
      entry: path.join(handlersDir, 'router.ts'),
      memorySize: 512,
      timeout: Duration.seconds(29),
      environment: {
        TABLE_NAME: table.tableName,
        USER_IMAGE_BUCKET: imageBucket.bucketName,
      },
    });

    const webhookFn = new NodejsFunction(this, 'WebhookFn', {
      ...commonFnProps,
      functionName: 'verdancy-revenuecat-webhook',
      entry: path.join(handlersDir, 'webhook.ts'),
      memorySize: 256,
      timeout: Duration.seconds(15),
      environment: {
        REVENUECAT_WEBHOOK_SECRET_ARN: webhookSecret.secretArn,
      },
    });
    webhookSecret.grantRead(webhookFn);

    // ---------------------------------------------------------------------
    // HTTP API — Cognito JWT authorizer on every route EXCEPT the webhook.
    // ---------------------------------------------------------------------
    const httpApi = new HttpApi(this, 'HttpApi', {
      apiName: 'verdancy-api',
      description: 'Verdancy HTTP API. JWT-authorized except POST /webhooks/revenuecat.',
    });

    const jwtAuthorizer = new HttpUserPoolAuthorizer('JwtAuthorizer', userPool, {
      userPoolClients: [client],
    });
    const routerIntegration = new HttpLambdaIntegration('RouterIntegration', routerFn);
    const webhookIntegration = new HttpLambdaIntegration('WebhookIntegration', webhookFn);

    const jwtRoutes: ReadonlyArray<{ path: string; methods: HttpMethod[] }> = [
      { path: '/users', methods: [HttpMethod.POST] },
      { path: '/uploads', methods: [HttpMethod.POST] },
      { path: '/identify', methods: [HttpMethod.POST] },
      { path: '/diagnose', methods: [HttpMethod.POST] },
      { path: '/plants', methods: [HttpMethod.POST, HttpMethod.GET] },
      { path: '/plants/{plantId}/care', methods: [HttpMethod.POST] },
      { path: '/plants/{plantId}', methods: [HttpMethod.DELETE] },
      { path: '/plants/{plantId}/photos', methods: [HttpMethod.POST, HttpMethod.GET] },
      { path: '/milestones', methods: [HttpMethod.POST] },
      { path: '/me/trees', methods: [HttpMethod.GET] },
    ];
    for (const r of jwtRoutes) {
      httpApi.addRoutes({
        path: r.path,
        methods: r.methods,
        integration: routerIntegration,
        authorizer: jwtAuthorizer,
      });
    }

    // The webhook is the only unauthenticated route — it verifies the shared
    // secret itself, so no JWT authorizer.
    httpApi.addRoutes({
      path: '/webhooks/revenuecat',
      methods: [HttpMethod.POST],
      integration: webhookIntegration,
      authorizer: new HttpNoneAuthorizer(),
    });

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
    new cdk.CfnOutput(this, 'HttpApiUrl', {
      value: httpApi.apiEndpoint,
      description: 'Base URL of the HTTP API (append route paths, e.g. /webhooks/revenuecat).',
    });
    new cdk.CfnOutput(this, 'DataTableName', {
      value: table.tableName,
      description: 'DynamoDB table name.',
    });
    new cdk.CfnOutput(this, 'UserImageBucketName', {
      value: imageBucket.bucketName,
      description: 'Private S3 bucket for user images.',
    });
    new cdk.CfnOutput(this, 'RevenueCatWebhookSecretName', {
      value: webhookSecret.secretName,
      description: 'Secrets Manager secret to read and paste into the RevenueCat dashboard.',
    });
  }
}
