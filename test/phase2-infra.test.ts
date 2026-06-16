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

  test('JWT on app routes, NONE on the webhook (13 routes total)', () => {
    t.resourceCountIs('AWS::ApiGatewayV2::Route', 13);
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /identify',
      AuthorizationType: 'JWT',
    });
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /webhooks/revenuecat',
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

  test('error-rate alarms exist for both Lambdas', () => {
    t.resourceCountIs('AWS::CloudWatch::Alarm', 2);
    t.hasResourceProperties('AWS::CloudWatch::Alarm', {
      Namespace: 'AWS/Lambda',
      MetricName: 'Errors',
    });
  });
});
