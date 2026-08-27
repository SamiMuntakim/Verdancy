import * as path from 'node:path';
import * as cdk from 'aws-cdk-lib';
import { Duration, RemovalPolicy, SecretValue } from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
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
 * Phase 2: DynamoDB single table, private S3 image bucket, the HTTP API with a
 *   Cognito JWT authorizer on every route except the secret-verified RevenueCat
 *   webhook, and the router + webhook Lambdas.
 * Phase 3: the handler logic — Gemini proxy with entitlement+quota, presigned
 *   uploads, CRUD with S3 cascade, milestones, and the webhook — plus the
 *   least-privilege IAM grants those need.
 * Post-MVP (Appendix A): the Plant Buddy sprite pipeline — a shared sprite bucket
 *   fronted by CloudFront, and a JWT-authed generation Lambda (POST /buddy).
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
        // Native Sign in with Apple mints tokens through the admin password flow in
        // the auth Lambda (backend-only; requires the Lambda's AWS credentials).
        adminUserPassword: true,
        // Email/password sign-in from the app (plain password over TLS to Cognito).
        userPassword: true,
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
    // Plant Buddy sprites (post-MVP, PRD Appendix A). A SEPARATE bucket from
    // user images: sprites are shared per-species and served read-only via
    // CloudFront (origin access control), not presigned per-user. The bucket
    // stays private; only the distribution can read it.
    // ---------------------------------------------------------------------
    const spriteBucket = new s3.Bucket(this, 'SpriteStore', {
      bucketName: `verdancy-sprites-${this.account}-${this.region}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      autoDeleteObjects: !retain,
      removalPolicy: retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });
    const spriteCdn = new cloudfront.Distribution(this, 'SpriteCdn', {
      comment: 'Verdancy shared plant-buddy sprites',
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(spriteBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
      },
    });
    const spriteCdnBase = `https://${spriteCdn.distributionDomainName}`;

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

    // The Gemini API key lives in Secrets Manager; the user creates/populates it
    // (it's an external key from Google AI Studio). Referenced by name so the
    // stack synths/deploys before the secret exists; /identify works once it does.
    const GEMINI_SECRET_NAME = 'verdancy/gemini-api-key';
    const geminiSecret = secretsmanager.Secret.fromSecretNameV2(
      this,
      'GeminiApiKey',
      GEMINI_SECRET_NAME,
    );

    // Tree-Nation API token (external, user-populated) — funds real tree
    // planting, so it's referenced by name and read only by the two Lambdas
    // that can grant trees.
    const TREENATION_SECRET_NAME = 'verdancy/treenation-api-token';
    const treeNationSecret = secretsmanager.Secret.fromSecretNameV2(
      this,
      'TreeNationApiToken',
      TREENATION_SECRET_NAME,
    );
    // Planting config. Tree-Nation honors a requested species_id as long as that
    // species is in stock (verified against the live API), so the client picks
    // the cheapest in-stock species in TREENATION_PROJECT_ID on every plant.
    // TARGET_TREE_PRICE_EUR is the price we intend to pay — if the cheapest
    // in-stock species costs more, we don't plant. MAX_TREE_PRICE_EUR bounds
    // what a mid-flight stock-out substitution may cost. DAILY_TREE_BUDGET is
    // the global circuit breaker (auto-refill can't be turned off).
    const treeEnv = {
      TREENATION_API_TOKEN_SECRET_NAME: TREENATION_SECRET_NAME,
      TREENATION_PROJECT_ID: '269',
      TARGET_TREE_PRICE_EUR: '0.35',
      MAX_TREE_PRICE_EUR: '0.50',
      DAILY_TREE_BUDGET: '30',
    };

    // ---------------------------------------------------------------------
    // Lambdas — Node.js 20.x, arm64. The Node 20 runtime provides the core
    // @aws-sdk client packages (kept external); @google/genai and
    // s3-request-presigner are bundled so they're guaranteed present.
    // ---------------------------------------------------------------------
    const handlersDir = path.join(__dirname, '..', 'src', 'handlers');
    const commonFnProps = {
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler',
      bundling: {
        externalModules: [
          '@aws-sdk/client-dynamodb',
          '@aws-sdk/lib-dynamodb',
          '@aws-sdk/client-s3',
          '@aws-sdk/client-secrets-manager',
          '@aws-sdk/client-cognito-identity-provider',
        ],
        minify: true,
        sourceMap: true,
        target: 'node20',
      },
    };

    // Explicit, cost-bounded log groups (default is never-expire).
    const logRemoval = retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;
    const routerLogGroup = new logs.LogGroup(this, 'RouterLogGroup', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: logRemoval,
    });
    const webhookLogGroup = new logs.LogGroup(this, 'WebhookLogGroup', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: logRemoval,
    });

    const routerFn = new NodejsFunction(this, 'RouterFn', {
      ...commonFnProps,
      functionName: 'verdancy-router',
      entry: path.join(handlersDir, 'router.ts'),
      memorySize: 512,
      timeout: Duration.seconds(29),
      logGroup: routerLogGroup,
      environment: {
        TABLE_NAME: table.tableName,
        USER_IMAGE_BUCKET: imageBucket.bucketName,
        USER_POOL_ID: userPool.userPoolId,
        GEMINI_API_KEY_SECRET_NAME: GEMINI_SECRET_NAME,
        IDENTIFY_MODEL_ID: 'gemini-3.5-flash',
        DIAGNOSE_MODEL_ID: 'gemini-3.5-flash',
        FREE_DAILY_AI_LIMIT: '2',
        SUBSCRIBER_DAILY_AI_LIMIT: '50',
        STREAK_TREE_INTERVAL: '30',
        ...treeEnv,
      },
    });
    // Least privilege: the table, the image-bucket objects (+ list for account
    // deletion), the Gemini key, and deleting the caller's own Cognito user.
    table.grantReadWriteData(routerFn);
    geminiSecret.grantRead(routerFn);
    treeNationSecret.grantRead(routerFn);
    routerFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
        resources: [imageBucket.arnForObjects('*')],
      }),
    );
    routerFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:ListBucket'],
        resources: [imageBucket.bucketArn],
      }),
    );
    routerFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['cognito-idp:AdminDeleteUser'],
        resources: [userPool.userPoolArn],
      }),
    );

    const webhookFn = new NodejsFunction(this, 'WebhookFn', {
      ...commonFnProps,
      functionName: 'verdancy-revenuecat-webhook',
      entry: path.join(handlersDir, 'webhook.ts'),
      memorySize: 256,
      timeout: Duration.seconds(15),
      logGroup: webhookLogGroup,
      environment: {
        TABLE_NAME: table.tableName,
        REVENUECAT_WEBHOOK_SECRET_ARN: webhookSecret.secretArn,
        ANNUAL_PRODUCT_ID: 'verdancy_annual',
        ...treeEnv,
      },
    });
    // Least privilege: read the webhook + Tree-Nation secrets; UpdateItem for
    // entitlement / referral-credit / milestone-claim writes, GetItem to read
    // referred_by, PutItem to record the trees actually planted.
    webhookSecret.grantRead(webhookFn);
    treeNationSecret.grantRead(webhookFn);
    table.grant(webhookFn, 'dynamodb:UpdateItem', 'dynamodb:GetItem', 'dynamodb:PutItem');

    // ---------------------------------------------------------------------
    // Native-federation auth. `POST /auth/apple` is unauthenticated (it verifies
    // Apple's identity token itself), then find-or-creates the pool user and mints
    // real user-pool tokens via the admin password flow (an ephemeral password it
    // sets and immediately uses). This lets the app do native Sign in with Apple
    // yet still receive a real Cognito JWT (hard invariant #1: identity stays the
    // verified user-pool `sub`).
    // ---------------------------------------------------------------------
    const authLogGroup = new logs.LogGroup(this, 'AuthLogGroup', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: logRemoval,
    });

    const authFn = new NodejsFunction(this, 'AuthFn', {
      ...commonFnProps,
      functionName: 'verdancy-auth',
      entry: path.join(handlersDir, 'auth.ts'),
      memorySize: 256,
      timeout: Duration.seconds(15),
      logGroup: authLogGroup,
      environment: {
        USER_POOL_ID: userPool.userPoolId,
        APP_CLIENT_ID: client.userPoolClientId,
        // Native Sign in with Apple sets the token audience to the app bundle id.
        APPLE_AUDIENCE: 'com.verdancy.app',
        // Google OAuth iOS client id — the audience of the Google ID token. Public
        // (ships in the app), not a secret.
        GOOGLE_CLIENT_ID:
          '463079233513-jr0tij8ftp393jnccot9brr7equs9skj.apps.googleusercontent.com',
      },
    });
    // Least privilege: only the admin actions needed to find-or-create the user and
    // mint tokens (admin password flow), scoped to this one pool.
    authFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: [
          'cognito-idp:AdminGetUser',
          'cognito-idp:AdminCreateUser',
          'cognito-idp:AdminSetUserPassword',
          'cognito-idp:AdminInitiateAuth',
        ],
        resources: [userPool.userPoolArn],
      }),
    );

    // Plant Buddy generation Lambda — heavier (image gen + pixel processing).
    const buddyLogGroup = new logs.LogGroup(this, 'BuddyLogGroup', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: logRemoval,
    });
    const buddyFn = new NodejsFunction(this, 'BuddyFn', {
      ...commonFnProps,
      functionName: 'verdancy-buddy',
      entry: path.join(handlersDir, 'buddy.ts'),
      memorySize: 1024,
      timeout: Duration.seconds(29),
      logGroup: buddyLogGroup,
      // The buddy handler imports the style-reference PNG; bundle it into the
      // JS as a Uint8Array via esbuild's `binary` loader.
      bundling: {
        ...commonFnProps.bundling,
        loader: { '.png': 'binary' },
      },
      environment: {
        TABLE_NAME: table.tableName,
        SPRITE_BUCKET: spriteBucket.bucketName,
        SPRITE_CDN_BASE: spriteCdnBase,
        GEMINI_API_KEY_SECRET_NAME: GEMINI_SECRET_NAME,
        BUDDY_MODEL_ID: 'gemini-3.1-flash-image',
      },
    });
    // Least privilege: table RW (read garden, claim/finalize the buddy item),
    // the Gemini key, and write-only access to sprite-bucket objects.
    table.grantReadWriteData(buddyFn);
    geminiSecret.grantRead(buddyFn);
    buddyFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:PutObject'],
        resources: [spriteBucket.arnForObjects('*')],
      }),
    );

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
    const buddyIntegration = new HttpLambdaIntegration('BuddyIntegration', buddyFn);
    const authIntegration = new HttpLambdaIntegration('AuthIntegration', authFn);

    const jwtRoutes: ReadonlyArray<{ path: string; methods: HttpMethod[] }> = [
      { path: '/users', methods: [HttpMethod.POST, HttpMethod.DELETE] },
      { path: '/uploads', methods: [HttpMethod.POST] },
      { path: '/identify', methods: [HttpMethod.POST] },
      { path: '/diagnose', methods: [HttpMethod.POST] },
      { path: '/plants', methods: [HttpMethod.POST, HttpMethod.GET] },
      { path: '/plants/{plantId}/care', methods: [HttpMethod.POST] },
      { path: '/plants/{plantId}/care-plan', methods: [HttpMethod.POST] },
      { path: '/plants/{plantId}', methods: [HttpMethod.DELETE, HttpMethod.PATCH] },
      { path: '/plants/{plantId}/photos', methods: [HttpMethod.POST, HttpMethod.GET] },
      { path: '/checkin', methods: [HttpMethod.POST] },
      { path: '/me/trees', methods: [HttpMethod.GET] },
      { path: '/trees/community', methods: [HttpMethod.GET] },
      { path: '/me/referral', methods: [HttpMethod.GET] },
      { path: '/referrals/redeem', methods: [HttpMethod.POST] },
    ];
    for (const r of jwtRoutes) {
      httpApi.addRoutes({
        path: r.path,
        methods: r.methods,
        integration: routerIntegration,
        authorizer: jwtAuthorizer,
      });
    }

    // Plant Buddy generation — JWT-authed, but its own (heavier) Lambda.
    httpApi.addRoutes({
      path: '/buddy',
      methods: [HttpMethod.POST],
      integration: buddyIntegration,
      authorizer: jwtAuthorizer,
    });

    // Unauthenticated routes — each verifies its own caller (the webhook by shared
    // secret, /auth/apple by verifying Apple's identity token), so no JWT
    // authorizer. These are the only routes without one.
    httpApi.addRoutes({
      path: '/webhooks/revenuecat',
      methods: [HttpMethod.POST],
      integration: webhookIntegration,
      authorizer: new HttpNoneAuthorizer(),
    });
    httpApi.addRoutes({
      path: '/auth/apple',
      methods: [HttpMethod.POST],
      integration: authIntegration,
      authorizer: new HttpNoneAuthorizer(),
    });
    httpApi.addRoutes({
      path: '/auth/google',
      methods: [HttpMethod.POST],
      integration: authIntegration,
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
    new cdk.CfnOutput(this, 'SpriteCdnUrl', {
      value: spriteCdnBase,
      description: 'CloudFront base URL for shared Plant Buddy sprites.',
    });
    new cdk.CfnOutput(this, 'SpriteBucketName', {
      value: spriteBucket.bucketName,
      description: 'Private S3 bucket holding generated buddy sprites (served via CloudFront).',
    });
  }
}
