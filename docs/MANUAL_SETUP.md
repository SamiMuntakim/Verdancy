# Verdancy — Manual Setup Runbook (from scratch)

This is **account/console work only you can do**. It's written for someone who has never used AWS,
Apple Developer, or Google Cloud. Decisions are made for you where possible.

## The plan: two stages

| Stage | What                                     | Cost                                              | Time                 | Blocks?                 |
| ----- | ---------------------------------------- | ------------------------------------------------- | -------------------- | ----------------------- |
| **A** | AWS account → deploy **email-only** auth | Free (card required to open account)              | ~30–45 min           | Do this first           |
| **B** | Add Sign in with Apple + Google          | Apple **$99/yr** + ~1–2 day approval; Google free | ~1–2 hrs of clicking | Optional, do when ready |

Email-only is a fully valid backend. Federation in Stage B is **purely additive** — same code, one
redeploy. So get Stage A working today; tackle Stage B when you're closer to the iOS app.

**Decisions already made for you:**

- **Region:** `us-west-1` (US East / N. Virginia). Use it everywhere.
- **IAM user name:** `verdancy-deploy`.
- Stage A needs **no domain prefix and no Apple/Google** — those are Stage B only.

---

# STAGE A — AWS from zero to a deployed email-only backend

## A1. Create your AWS account (~10 min)

1. Go to <https://aws.amazon.com> → **Create an AWS Account** (top-right).
2. **Root email + account name:** use an email you control; account name `Verdancy`. Verify the email
   with the code AWS sends.
3. **Root password:** set a strong one (save it in a password manager).
4. **Contact info:** choose **Personal**, fill in name/phone/address, accept the terms.
5. **Billing:** enter a credit/debit card. AWS may place a temporary ~$1 authorization hold. At our
   scale everything here is within the AWS Free Tier (~$0/mo), but a card is required to open the
   account.
6. **Identity verification:** enter the SMS/voice code AWS sends to your phone.
7. **Support plan:** choose **Basic support — Free**.
8. You'll land on a "Congratulations" page → **Go to the AWS Management Console** and sign in as
   **Root user** with the email/password from above.

## A2. Secure the root account with MFA (~3 min, strongly recommended)

1. In the console search bar (top), type **IAM** and open it.
2. You may see a "Root user has MFA" warning → **Add MFA**. (Or: top-right account menu → **Security
   credentials** → **Multi-factor authentication (MFA)** → **Assign MFA device**.)
3. Pick **Authenticator app**, install one on your phone if needed (Google Authenticator, Authy,
   1Password, Microsoft Authenticator…), scan the QR code, enter two consecutive codes. Done.

> Root is the all-powerful account owner. After this, you'll do day-to-day work as the IAM user below
> and rarely touch root.

## A3. Set the console region (~30 sec)

Top-right of the console, click the region selector and choose **US East (N. Virginia) us-west-1**.
This makes the console show the same region we deploy to.

## A4. Create the deploy user `verdancy-deploy` (~5 min)

1. Open **IAM** → left sidebar **Users** → **Create user**.
2. **User name:** `verdancy-deploy`. Leave "Provide user access to the AWS Management Console"
   **unchecked** (this user is just for command-line deploys). **Next**.
3. **Set permissions** → **Attach policies directly** → search and check **AdministratorAccess**.
   (Broad, but the simplest path for a solo MVP — we can scope it down later.) **Next** → **Create user**.
4. Click the new `verdancy-deploy` user → **Security credentials** tab → scroll to **Access keys** →
   **Create access key**.
5. Use case: **Command Line Interface (CLI)** → check the confirmation box → **Next** → **Create
   access key**.
6. **Download the .csv file** (or copy both values now). It has the **Access key ID** and **Secret
   access key**. The secret is shown **only once** — keep the file safe; it's like a password.

## A5. Install the AWS CLI (~3 min, Windows)

1. In PowerShell, run:
   ```
   msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
   ```
   (or download/run the MSI from <https://awscli.amazonaws.com/AWSCLIV2.msi>).
2. **Close and reopen** your terminal, then verify:
   ```
   aws --version
   ```
   You should see something like `aws-cli/2.x.x`.

## A6. Connect the CLI to your account (~2 min)

```
aws configure
```

Enter, when prompted:

- **AWS Access Key ID** → from the .csv in A4
- **AWS Secret Access Key** → from the .csv in A4
- **Default region name** → `us-west-1`
- **Default output format** → `json`

Verify it worked:

```
aws sts get-caller-identity
```

This prints your account info. **Copy the 12-digit `Account` number** — call it `ACCOUNT_ID`.

## A7. Prepare CDK for your account (~3 min, one time)

From the project folder `C:\Users\Sami\Documents\GitHub\Verdancy`, run (substitute your `ACCOUNT_ID`):

```
npx cdk bootstrap aws://ACCOUNT_ID/us-west-1
```

This creates a small CDK support stack in your account. Takes a minute or two.

## A8. Deploy the email-only backend (~3 min)

```
npx cdk deploy
```

Review the prompt (it lists the IAM permissions being created) and type **`y`**. When it finishes,
it prints **Outputs**:

- `UserPoolId`
- `UserPoolClientId`
- `Region`
- `EnabledIdentityProviders` (will say `COGNITO` only, i.e. email — correct for Stage A)

**That's a live auth backend.** 🎉 Confirm it mints a real JWT (SRP flow, same as the app will use):

```
# create a confirmed test user (uses your AWS CLI creds; replace POOL_ID/region)
aws cognito-idp admin-create-user --user-pool-id POOL_ID --username smoketest@verdancy.test --message-action SUPPRESS --user-attributes Name=email,Value=smoketest@verdancy.test Name=email_verified,Value=true --region us-west-1
aws cognito-idp admin-set-user-password --user-pool-id POOL_ID --username smoketest@verdancy.test --password "TestPass123!@#" --permanent --region us-west-1

# authenticate and print the JWT claims (replace POOL_ID / CLIENT_ID)
node scripts/smoke-auth.mjs POOL_ID CLIENT_ID smoketest@verdancy.test "TestPass123!@#"
```

> Costs so far: effectively $0 (Free Tier). In dev the pool is **destroyable**, so `npx cdk destroy`
> cleans everything up (and a failed deploy rolls back without orphaning anything). Before you have
> real users, deploy production with `-c retainResources=true` to deletion-protect and retain the pool.

---

# STAGE B — Add Sign in with Apple + Google (later)

Do this when you're ready to wire real social login (often alongside iOS app work). It needs:

- **Apple Developer Program** enrollment — **$99/year**, ~1–2 day approval:
  <https://developer.apple.com/programs/enroll/>. Required for Sign in with Apple (and to ship any
  iOS app). **If you want, start the enrollment now** so the clock runs while you do Stage A.
- A **Google account** (free) for Google Cloud Console.

When you reach Stage B, we'll first pick a **globally-unique Cognito domain prefix** together
(e.g. `verdancy-auth-prod`); your federation redirect URL becomes
`https://PREFIX.auth.us-west-1.amazoncognito.com/oauth2/idpresponse`.

### B1. Apple (at developer.apple.com/account → Certificates, Identifiers & Profiles)

- **Team ID:** Membership page, 10 chars → `apple:teamId`.
- **App ID:** Identifiers → (+) → App IDs → App. Bundle ID **Explicit** `com.verdancy.app`, enable
  **Sign In with Apple** → Register.
- **Services ID:** Identifiers → (+) → Services IDs. Identifier `com.verdancy.signin` →
  `apple:servicesId`. Register, open it, tick **Sign In with Apple → Configure**:
  - Primary App ID: `com.verdancy.app`
  - Domains and Subdomains: `PREFIX.auth.us-west-1.amazoncognito.com` (**no `https://`**)
  - Return URLs: `https://PREFIX.auth.us-west-1.amazoncognito.com/oauth2/idpresponse`
  - (No domain-verification file needed — that's for a flow Cognito doesn't use.)
- **Key (.p8):** Keys → (+), enable Sign in with Apple, set Primary App ID, Register, **download the
  `.p8` (one time only)**, note the **Key ID** → `apple:keyId`.

### B2. Google (at console.cloud.google.com)

- Create a project. **APIs & Services → OAuth consent screen → External**, fill app name/emails, add
  yourself as a Test user (publish before public launch).
- **Credentials → Create Credentials → OAuth client ID → Web application**:
  - Authorized JavaScript origins: `https://PREFIX.auth.us-west-1.amazoncognito.com`
  - Authorized redirect URIs: `https://PREFIX.auth.us-west-1.amazoncognito.com/oauth2/idpresponse`
  - Copy **Client ID** (`…apps.googleusercontent.com` → `google:clientId`) and **Client secret**
    (`GOCSPX-…`).

### B3. Store the two secrets (same region!)

```
aws secretsmanager create-secret --name verdancy/apple-signin-key  --secret-string file://C:\path\to\AuthKey_KEY1234567.p8 --region us-west-1
aws secretsmanager create-secret --name verdancy/google-oauth-secret --secret-string "GOCSPX-your-secret" --region us-west-1
```

### B4. Send me the non-secret values

REGION, ACCOUNT_ID, PREFIX, Apple Services ID, Apple Team ID, Apple Key ID, Google Client ID. I wire
a gitignored `cdk.context.json`; you run `npx cdk deploy` again and federation goes live. **Never send
the `.p8` contents or the Google secret** — those live only in Secrets Manager.

---

# PHASE 3 — runtime secrets & RevenueCat (after you deploy Phase 3)

Phase 3 adds the AI proxy and the entitlement webhook. Two manual steps make them work; the stack
deploys fine without them (the routes just return errors until the secrets exist).

### C1. Gemini API key

1. Get an API key from Google AI Studio (<https://aistudio.google.com/apikey>).
2. Store it (same region) — the router reads it by this name:
   ```
   aws secretsmanager create-secret --name verdancy/gemini-api-key --secret-string "YOUR_GEMINI_KEY" --region us-west-1
   ```
   `/identify` and `/diagnose` work once this exists.

### C2. RevenueCat webhook

CDK generates the shared secret; read it and configure RevenueCat to match:

```
aws secretsmanager get-secret-value --secret-id verdancy/revenuecat-webhook-secret --query SecretString --output text --region us-west-1
```

In the RevenueCat dashboard → project → Integrations → Webhooks:

- **URL**: `<HttpApiUrl>/webhooks/revenuecat` (from the deploy outputs)
- **Authorization header**: paste the secret value from the command above
- Set the app's **`appUserID` to the Cognito `sub`** so events map to the right user.

### C4. Plant Buddy sprites (post-MVP)

No extra secret — the buddy Lambda reuses `verdancy/gemini-api-key`. Notes:

- The sprite bucket + CloudFront deploy automatically; the first CloudFront deploy takes a few
  minutes. The CDN base URL is the `SpriteCdnUrl` output.
- The image model is set by `BUDDY_MODEL_ID` (default `gemini-2.5-flash-image`). If your Gemini
  account uses a different image-generation model id, set it on the `verdancy-buddy` Lambda.
- The locked palette + style prompt live in `src/lib/buddy.ts` / `src/lib/gemini.ts`. To revamp the
  art, change them and bump `STYLE_VERSION` (sprites re-cache under a new key).

### C3. Smoke-test the live API (optional)

After deploy, exercise the non-AI endpoints end to end (no Gemini cost). Get a JWT from the
email/password smoke test, then run the API smoke test with the `HttpApiUrl` output:

```
node scripts/smoke-auth.mjs <UserPoolId> <ClientId> smoketest@verdancy.test "TestPass123!@#"
node scripts/smoke-api.mjs  <HttpApiUrl> <idToken-from-above>
```

It runs users → uploads → presigned PUT/GET → plant CRUD → care → milestone idempotency → delete
cascade, printing a pass/fail line per step.

---

## Value cheat-sheet (Stage B)

| You collect   | From                         | Used as                               |
| ------------- | ---------------------------- | ------------------------------------- |
| Team ID       | Apple → Membership           | `apple:teamId`                        |
| Services ID   | Apple → Services IDs         | `apple:servicesId`                    |
| Key ID        | Apple → Keys                 | `apple:keyId`                         |
| `.p8` file    | Apple → Keys (download once) | Secret `verdancy/apple-signin-key`    |
| Client ID     | Google → Credentials         | `google:clientId`                     |
| Client secret | Google → Credentials         | Secret `verdancy/google-oauth-secret` |
| Domain prefix | we pick together             | `cognito:domainPrefix`                |
