#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { VerdancyStack } from '../lib/verdancy-stack';
import { readAuthConfig } from '../lib/config';

const app = new cdk.App();

new VerdancyStack(app, 'VerdancyStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  description: 'Verdancy backend — Phase 1: Cognito (Sign in with Apple + Google + email).',
  auth: readAuthConfig(app),
});

app.synth();
