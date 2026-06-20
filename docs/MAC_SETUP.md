# Verdancy — Mac / Xcode runbook

Everything to do on the MacBook to get the iOS app building, then connected to the real backend,
then shippable. The Swift was authored on Windows and is **not compiler-verified** — expect a few
fixups on the first build (most likely in the RevenueCat/Amplify calls).

> **Strong tip:** install **Claude Code** on the Mac (`https://claude.ai/code`) and run it inside the
> cloned repo. On macOS it can run `xcodegen`, `xcodebuild`, and the simulator, so it can compile the
> app and fix the build errors with you — which it can't do on Windows.

Known values from your setup: region **us-west-1**, AWS account **532918216148**, bundle id
**`com.verdancy.app`**, Cognito (Phase 1, email-only) **UserPoolId `us-west-1_3nSrmRffE`**,
**ClientId `6jsmcp3h5g51brqas321f94u3`**. (Use the actual `cdk deploy` outputs as the source of truth.)

---

## 0. Toolchain (~30–60 min, mostly Xcode download)

1. **Xcode** — install from the Mac App Store (large, slow). Open it once to finish component install,
   then `sudo xcodebuild -license accept` and `xcode-select --install` (command-line tools).
2. **Homebrew** — <https://brew.sh>.
3. **XcodeGen** — `brew install xcodegen`.
4. (Recommended) **Claude Code** + the **GitHub CLI** (`brew install gh`).
5. **Clone the repo:**
   ```
   git clone https://github.com/SamiMuntakim/Verdancy.git
   cd Verdancy
   ```

---

## Milestone A — run the app in the simulator (mock mode, no backend) ✅ first win

The app ships with `AppConfig.useMockAuth = true`, so it runs fully offline with sample data.

1. Generate + open the project:
   ```
   cd ios
   xcodegen generate
   open Verdancy.xcodeproj
   ```
   Xcode auto-resolves the two Swift Package deps (RevenueCat, Amplify) — wait for "Package
   resolution" to finish.
2. **Signing:** select the `Verdancy` target → **Signing & Capabilities** → check _Automatically
   manage signing_ and pick your **Team** (your enrolled Apple Developer account). (Or set
   `DEVELOPMENT_TEAM` in `ios/project.yml` and re-run `xcodegen generate`.)
3. Pick an **iPhone 15 simulator** and press **⌘R**.
4. **Fix build errors.** This is the expected step for the unverified Swift — start here with Claude
   Code (or paste the errors to me). Likely spots: `EntitlementService.swift` (RevenueCat API) and
   `AmplifyAuthService.swift` (Amplify API).

**Done when:** the app launches, you can tab through Today / Scan / My Oasis / Settings, run a mock
scan→save, hit the paywall → see the bloom, and toggle appearance.

---

## Milestone B — connect the real backend (data + AI + Apple sign-in)

### B1. Deploy the backend (Phase 2/3 + buddy)

Only Phase 1 (Cognito) is deployed. Deploy the rest. You can do this from the Windows box (AWS CLI
already configured there) or set it up on the Mac:

```
# (Mac only, if not reusing Windows) install + configure AWS CLI:
brew install awscli && aws configure        # use the verdancy-deploy keys, region us-west-1

cd Verdancy            # repo root
npm install
npx cdk deploy
```

Note the outputs, especially **`HttpApiUrl`**, `UserPoolId`, `UserPoolClientId`,
`RevenueCatWebhookSecretName`, `SpriteCdnUrl`.

### B2. Gemini API key (for /identify, /diagnose, /buddy)

Get a key from <https://aistudio.google.com/apikey>, then:

```
aws secretsmanager create-secret --name verdancy/gemini-api-key --secret-string "YOUR_KEY" --region us-west-1
```

### B3. Stage B — Sign in with Apple + Cognito federation (the app's auth)

The app signs in with Apple via Amplify's hosted domain, so you must wire **Stage B** (full steps in
[`MANUAL_SETUP.md`](MANUAL_SETUP.md) §Stage B). In short:

- Apple Developer: **App ID** `com.verdancy.app` with _Sign In with Apple_ enabled; a **Services ID**
  (e.g. `com.verdancy.signin`); a **Sign in with Apple key (.p8)** (note Key ID + your Team ID). In
  the Services ID, set Return URL `https://PREFIX.auth.us-west-1.amazoncognito.com/oauth2/idpresponse`.
- Store the key: `aws secretsmanager create-secret --name verdancy/apple-signin-key --secret-string file://AuthKey_XXX.p8 --region us-west-1`.
- Pick a globally-unique `PREFIX` and **send me** PREFIX + Apple Services ID / Team ID / Key ID; I'll
  bake `cdk.context.json` and you redeploy: `npx cdk deploy`. This updates the **same** pool/client
  (IDs unchanged) and adds the hosted domain.

### B4. Point the iOS app at the backend

In `ios/Verdancy/`:

1. **`Config/AppConfig.swift`** — set `apiBaseURL` to the `HttpApiUrl`, and `useMockAuth = false`.
2. **`Resources/amplifyconfiguration.json`** — copy from `amplifyconfiguration.template.json` and fill
   in: `PoolId` = `us-west-1_3nSrmRffE`, `AppClientId` = `6jsmcp3h5g51brqas321f94u3`, `Region` =
   `us-west-1`, `WebDomain` = `PREFIX.auth.us-west-1.amazoncognito.com`. (The real file is gitignored.)
3. **URL scheme for the auth callback** — add to `Resources/Info.plist` so the `verdancy://auth/callback`
   redirect returns to the app:
   ```xml
   <key>CFBundleURLTypes</key>
   <array><dict>
     <key>CFBundleURLSchemes</key><array><string>verdancy</string></array>
   </dict></array>
   ```
4. **Capability:** Signing & Capabilities → **+ Capability → Sign in with Apple** (the entitlement is
   already in `Verdancy.entitlements`; this links it to your App ID).
5. `xcodegen generate` (if you changed `project.yml`/Info.plist) and run.

**Done when:** Sign in with Apple works, the garden loads from the API, and a real scan
identifies/saves a plant. (`scripts/smoke-api.mjs` from the repo root is a quick backend sanity check.)

---

## Milestone C — subscriptions (RevenueCat + App Store Connect)

### C1. App Store Connect

1. <https://developer.apple.com/account> → Identifiers → confirm the **App ID `com.verdancy.app`**.
2. <https://appstoreconnect.apple.com> → **My Apps → +** → create the app (bundle id `com.verdancy.app`).
3. Enroll in **Apple Small Business Program** (85% — your margins assume it).
4. **In-App Purchases** → create two **auto-renewable subscriptions** in one subscription group:
   - Annual — **$39.99/yr** with a **7-day free trial** (Introductory Offer).
   - Monthly — **$7.99/mo**.
     Fill in the localizations/review info (they must be "Ready to Submit" to test).

### C2. RevenueCat

1. <https://app.revenuecat.com> → create a project, add your **App Store** app (App-Specific Shared
   Secret from App Store Connect).
2. Create an **entitlement** with identifier **`premium`** (matches `AppConfig.entitlementID`).
3. Create **products** (annual, monthly) → attach to `premium` → build an **Offering** (default) with
   an **annual** and a **monthly** package.
4. Copy the **public SDK key** → `AppConfig.revenueCatAPIKey`.
5. **Webhook:** Integrations → Webhooks → URL `=<HttpApiUrl>/webhooks/revenuecat`, Authorization header
   = the value from
   `aws secretsmanager get-secret-value --secret-id verdancy/revenuecat-webhook-secret --query SecretString --output text --region us-west-1`.
   (The app already sets `appUserID` = Cognito `sub`, so events map to the user.)

**Done when:** the paywall shows real prices, a sandbox purchase flips `isSubscribed`, fires the bloom,
and the webhook flips `entitlement_active` server-side.

---

## Milestone D — ship

1. **App metadata** in App Store Connect: name, subtitle, description, keywords, **screenshots**
   (6.7" + 6.1"), category (Lifestyle), **age rating**.
2. **Privacy:** host a Privacy Policy + Terms; fill the **App Privacy** "nutrition labels"
   (you collect: account/email, plant photos, purchases). Confirm the in-app **Delete account** flow
   works (Guideline 5.1.1(v) — built).
3. **Sign in with Apple is required** (Guideline 4.8, since you offer it) — already configured.
4. **TestFlight:** Product → Archive → upload → internal testing → install on your device.
5. **Submit for review** with the subscriptions.

---

## Known rough edges (where to ping me)

- **RevenueCat / Amplify Swift API exactness** — the most likely first compile errors (`EntitlementService.swift`,
  `AmplifyAuthService.swift`). Easiest to fix with Claude Code on the Mac.
- **Native Sign in with Apple** — the app uses Amplify's hosted-domain flow (the supported Cognito path).
  A fully-native `ASAuthorizationController` flow is a separate decision if you want the system sheet.
- **Bud sprite art** — the views render symbolic placeholders; drop in real pixel sprites when ready.
- **Referral attribution** — the invite share UI exists; crediting "a tree for both" needs a small
  backend endpoint (I can build it once you pick an invite-code scheme).
