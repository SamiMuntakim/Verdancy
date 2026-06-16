// Phase 1 smoke test: prove the Cognito user pool mints a valid JWT.
//
// Authenticates a test user with the SECURE SRP flow (USER_SRP_AUTH) — the same
// flow the iOS app uses — so we verify the real client without weakening it.
//
// Usage:
//   node scripts/smoke-auth.mjs <UserPoolId> <ClientId> <username> <password>
//
// Create the test user first (needs your AWS CLI creds), e.g.:
//   aws cognito-idp admin-create-user --user-pool-id <UserPoolId> \
//     --username smoketest@verdancy.test --message-action SUPPRESS \
//     --user-attributes Name=email,Value=smoketest@verdancy.test Name=email_verified,Value=true \
//     --region <region>
//   aws cognito-idp admin-set-user-password --user-pool-id <UserPoolId> \
//     --username smoketest@verdancy.test --password "<password>" --permanent --region <region>

import AmazonCognitoIdentity from 'amazon-cognito-identity-js';

const { CognitoUserPool, CognitoUser, AuthenticationDetails } = AmazonCognitoIdentity;

const [, , userPoolId, clientId, username, password] = process.argv;

if (!userPoolId || !clientId || !username || !password) {
  console.error('Usage: node scripts/smoke-auth.mjs <UserPoolId> <ClientId> <username> <password>');
  process.exit(2);
}

const pool = new CognitoUserPool({ UserPoolId: userPoolId, ClientId: clientId });
const user = new CognitoUser({ Username: username, Pool: pool });
const details = new AuthenticationDetails({ Username: username, Password: password });

user.authenticateUser(details, {
  onSuccess: (session) => {
    const idToken = session.getIdToken().getJwtToken();
    const claims = JSON.parse(Buffer.from(idToken.split('.')[1], 'base64url').toString('utf8'));
    console.log('✅ Authenticated — your pool minted a valid Cognito JWT.\n');
    console.log('   sub:       ', claims.sub);
    console.log('   email:     ', claims.email);
    console.log('   token_use: ', claims.token_use);
    console.log('   iss:       ', claims.iss);
    console.log('   expires:   ', new Date(claims.exp * 1000).toISOString());
    console.log('\n   id_token (truncated):', idToken.slice(0, 48) + '…');
    process.exit(0);
  },
  onFailure: (err) => {
    console.error('❌ Authentication failed:', err?.message ?? err);
    process.exit(1);
  },
  newPasswordRequired: () => {
    console.error(
      '❌ User is in FORCE_CHANGE_PASSWORD. Set a permanent password first:\n' +
        '   aws cognito-idp admin-set-user-password --user-pool-id ' +
        userPoolId +
        ' --username <user> --password "<pw>" --permanent --region <region>',
    );
    process.exit(1);
  },
});
