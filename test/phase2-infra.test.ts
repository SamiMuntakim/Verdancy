import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { VerdancyStack } from '../lib/verdancy-stack';
import type { AuthConfig } from '../lib/config';

const auth: AuthConfig = {
  callbackUrls: ['verdancy://auth/callback'],
  logoutUrls: ['verdancy://auth/logout'],
};

// Synthesize once (this bundles the Lambdas) and share the read-only template.
const app = new cdk.App();
const stack = new VerdancyStack(app, 'Phase2Stack', {
  env: { account: '123456789012', region: 'us-west-1' },
  auth,
});
const t = Template.fromStack(stack);

describe('DynamoDB table', () => {
  test('single on-demand table: PK/SK, TTL on expires_at, no GSI', () => {
    t.resourceCountIs('AWS::DynamoDB::Table', 1);
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      BillingMode: 'PAY_PER_REQUEST',
      KeySchema: [
        { AttributeName: 'PK', KeyType: 'HASH' },
        { AttributeName: 'SK', KeyType: 'RANGE' },
      ],
      TimeToLiveSpecification: { AttributeName: 'expires_at', Enabled: true },
      GlobalSecondaryIndexes: Match.absent(),
    });
  });
});

describe('S3 image bucket', () => {
  test('blocks all public access', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
    });
  });

  test('enforces TLS via a deny-non-HTTPS bucket policy', () => {
    t.hasResourceProperties('AWS::S3::BucketPolicy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Deny',
            Condition: { Bool: { 'aws:SecureTransport': 'false' } },
          }),
        ]),
      },
    });
  });

  test('tiers cold objects to Intelligent-Tiering', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      LifecycleConfiguration: {
        Rules: Match.arrayWith([
          Match.objectLike({
            Transitions: Match.arrayWith([
              Match.objectLike({ StorageClass: 'INTELLIGENT_TIERING' }),
            ]),
          }),
        ]),
      },
    });
  });
});

describe('Lambdas', () => {
  test('router + webhook run on Node 20', () => {
    t.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'verdancy-router',
      Runtime: 'nodejs20.x',
    });
    t.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'verdancy-revenuecat-webhook',
      Runtime: 'nodejs20.x',
    });
  });

  test('webhook is granted read on its secret', () => {
    t.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({ Action: Match.arrayWith(['secretsmanager:GetSecretValue']) }),
        ]),
      },
    });
  });
});

describe('HTTP API + JWT authorizer', () => {
  test('one HTTP API with a Cognito JWT authorizer', () => {
    t.resourceCountIs('AWS::ApiGatewayV2::Api', 1);
    t.hasResourceProperties('AWS::ApiGatewayV2::Authorizer', { AuthorizerType: 'JWT' });
  });

  test('JWT on app routes, NONE on the webhook + /auth/{apple,google} (21 routes total)', () => {
    t.resourceCountIs('AWS::ApiGatewayV2::Route', 21);
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /identify',
      AuthorizationType: 'JWT',
    });
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /plants/{plantId}/care-plan',
      AuthorizationType: 'JWT',
    });
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /webhooks/revenuecat',
      AuthorizationType: 'NONE',
    });
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /auth/apple',
      AuthorizationType: 'NONE',
    });
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /auth/google',
      AuthorizationType: 'NONE',
    });
  });
});

describe('RevenueCat webhook secret', () => {
  test('a generated secret exists', () => {
    t.hasResourceProperties('AWS::SecretsManager::Secret', {
      Name: 'verdancy/revenuecat-webhook-secret',
    });
  });
});

describe('Operational hardening (PRD 3.8)', () => {
  test('Lambda log groups have a bounded (1-month) retention', () => {
    t.hasResourceProperties('AWS::Logs::LogGroup', { RetentionInDays: 30 });
  });

  test('no CloudWatch alarms (removed to minimize infra; bounded log retention remains)', () => {
    t.resourceCountIs('AWS::CloudWatch::Alarm', 0);
  });
});

describe('Native-federation auth (POST /auth/apple)', () => {
  test('the auth Lambda runs on Node 20', () => {
    t.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'verdancy-auth',
      Runtime: 'nodejs20.x',
    });
  });

  test('there is no custom-auth trigger Lambda (simplified to admin auth)', () => {
    const fns = t.findResources('AWS::Lambda::Function');
    const names = Object.values(fns).map(
      (f) => (f as { Properties: { FunctionName?: string } }).Properties.FunctionName,
    );
    expect(names).not.toContain('verdancy-auth-challenge');
  });

  test('the app client enables admin (federated) + user (email) password flows', () => {
    t.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      ExplicitAuthFlows: Match.arrayWith(['ALLOW_ADMIN_USER_PASSWORD_AUTH']),
    });
    t.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      ExplicitAuthFlows: Match.arrayWith(['ALLOW_USER_PASSWORD_AUTH']),
    });
  });

  test('the auth Lambda holds only scoped Cognito admin actions (no wildcard)', () => {
    const policies = t.findResources('AWS::IAM::Policy');
    const stmts = Object.values(policies).flatMap(
      (p) =>
        (p as { Properties: { PolicyDocument: { Statement: Array<Record<string, unknown>> } } })
          .Properties.PolicyDocument.Statement,
    );
    const adminStmt = stmts.find((s) => {
      const action = s.Action;
      const actions = Array.isArray(action) ? action : [action];
      return actions.some(
        (a) => typeof a === 'string' && a.startsWith('cognito-idp:AdminInitiateAuth'),
      );
    });
    expect(adminStmt).toBeDefined();
    const actions = adminStmt!.Action as string[];
    expect(actions).toEqual(
      expect.arrayContaining([
        'cognito-idp:AdminGetUser',
        'cognito-idp:AdminCreateUser',
        'cognito-idp:AdminSetUserPassword',
        'cognito-idp:AdminInitiateAuth',
      ]),
    );
    expect(actions).not.toContain('cognito-idp:AdminRespondToAuthChallenge');
    expect(actions).not.toContain('cognito-idp:*');
    expect(actions).not.toContain('*');
  });
});
