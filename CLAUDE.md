# CLAUDE.md — Verdancy Backend

This file is the operating manual for working in this repo. **`PRD.md` is the source of truth for *what* to build** (data model, routes, phases, acceptance criteria); this file is *how* to work and the rules you must not break. Read both before starting.

Verdancy is a subscription iOS plant ID + care app. This repo is the **backend only**: AWS CDK (TypeScript) defining Cognito, an HTTP API, Lambda handlers, DynamoDB, and an S3 image bucket. iOS (Swift) lives elsewhere.

---

## Workflow

- **Build in the PRD's phases (Section 7). Stop and ask for confirmation before starting each phase.** Do not jump ahead.
- **`cdk synth` must pass before any infra work is considered done.** Run it after every stack change.
- **Turn the Phase 3 acceptance criteria into real integration tests** (auth checks, quota rollover, milestone idempotency, presign ownership). Correctness here is verified by running tests, not by reading the diff — the security paths look identical whether or not they're correct.
- Work in **small commits**, one logical change each, so reverting is clean.
- When unsure about a security or money path, ask rather than guess.

## Commands

```bash
npm install
npm run build          # tsc
npx cdk synth          # validate — run after every stack edit
npx cdk diff           # review before deploy
npx cdk deploy         # deploy to the configured account/region
npm test               # jest: unit tests for handlers + integration checks
npm run lint           # eslint + prettier
```

## Project layout

```
bin/verdancy.ts          # CDK app entry
lib/verdancy-stack.ts    # the single stack (Cognito, HTTP API, Lambda, DynamoDB, S3)
src/handlers/router.ts   # main router Lambda (AI proxy + CRUD)
src/handlers/webhook.ts  # RevenueCat webhook Lambda (secret-verified, no JWT)
src/lib/                 # shared: dynamo client, gemini client, auth/ownership helpers, error shapes
test/                    # jest
```

---

## HARD INVARIANTS — never violate these

These are the regression-prone rules. If a change would break one, stop and flag it.

1. **Identity comes only from the verified JWT `sub`.** Never read user identity from the request body, query string, or a client-supplied field.
2. **Object-level authorization on everything.** Every `{plantId}` route and every presigned-URL request must confirm the resource belongs to the caller (S3 keys live under `u/<sub>/…`) → else `403`/`404`. A user must never touch another user's plant, photo, or image.
3. **Reserve quota BEFORE calling Gemini.** Never call Gemini until the reservation write succeeds.
   - Subscriber (`entitlement_active=true`): atomic `ADD count :one` on `QUOTA#<today>` with condition `attribute_not_exists(count) OR count < :SUBSCRIBER_DAILY_AI_LIMIT` → `429` on failure.
   - Non-subscriber: atomic `ADD free_ai_used :one` on `METADATA` with condition `free_ai_used < :FREE_AI_LIFETIME_LIMIT` → `402` on failure.
4. **Daily quota is date-keyed with TTL.** Use a `QUOTA#<YYYY-MM-DD>` item with an `expires_at` TTL. Never store a mutable rolling counter + date on the METADATA item (that path has a rollover race).
5. **Milestone increment is ONE atomic conditional `UpdateItem`** (`ADD milestones :midSet, trees_pledged :one` with `ConditionExpression: NOT contains(milestones, :mid)`). Never read-then-write — it double-counts on concurrent submits.
6. **Image bytes never pass through Lambda.** Uploads and downloads use presigned S3 URLs only; Lambda issues the URLs, never proxies the bytes. (The *only* images Lambda touches are the inline bytes sent to `/identify` and `/diagnose`, which are forwarded to Gemini and immediately discarded — never written to S3.)
7. **The server generates S3 keys** under `u/<sub>/p/<plantId>/<uuid>.jpg`. The app never supplies or chooses a key.
8. **Never emit a fake care schedule.** On low `confidence` or an unidentifiable plant: `common_name = "Unknown Plant"`, `water_cadence_days = null`, `toxicity = "High"`. When genuinely uncertain between watering intervals, return the **longer** one — overwatering is the top plant killer and the top churn risk.
9. **Entitlement truth is server-side** (`entitlement_active` in DynamoDB, set by the RevenueCat webhook). Never gate AI access on a client-asserted subscription status.
10. **Secrets only from Secrets Manager.** Never hardcode the Gemini key or webhook secret. Never log JWTs, images, secrets, or PII.
11. **One DynamoDB table, no GSIs.** Don't add a GSI or a second table without explicit approval — the access patterns don't need one.
12. **Least-privilege IAM.** Scope each Lambda's actions to the one table (and the image-bucket prefix for the router); never use `*` on actions or resources.

---

## Stack-specific facts (do not rely on training data for these)

- **Gemini SDK is `@google/genai`** (`import { GoogleGenAI } from "@google/genai"`). The legacy `@google/generative-ai` is **deprecated/EOL — do not use it.**
- **Models come from env** (`IDENTIFY_MODEL_ID`, `DIAGNOSE_MODEL_ID`), default **`gemini-3.5-flash`**. Do **not** downgrade to a Lite tier — care accuracy is a retention lever. Structured output goes in `config: { responseMimeType: "application/json", responseSchema }`; wrap `JSON.parse` in try/catch.
- **Cognito uses native Sign in with Apple** as a federated IdP (+ Google + email), **not** the Hosted UI web redirect. App Store Guideline 4.8 requires Sign in with Apple because we offer Google.
- **API Gateway is the HTTP API** (not REST) with a Cognito JWT authorizer on all routes **except** `POST /webhooks/revenuecat` (secret-verified).
- **Lambda runtime: Node.js 20.x.**
- **RevenueCat `appUserID` = Cognito `sub`** so webhook events map to a user.

## Environment variables

`TABLE_NAME`, `USER_IMAGE_BUCKET`, `GEMINI_API_KEY` (Secrets Manager), `REVENUECAT_WEBHOOK_SECRET` (Secrets Manager), `IDENTIFY_MODEL_ID`, `DIAGNOSE_MODEL_ID`, `FREE_AI_LIFETIME_LIMIT`, `SUBSCRIBER_DAILY_AI_LIMIT`.

## Error shapes

Return clean JSON errors with these statuses only: `200 / 400 / 401 / 402 / 403 / 404 / 429 / 500`. `402` = free allowance exhausted (client shows paywall). `429` = subscriber daily cap hit.

---

## Do NOT

- Store user images in CloudKit or DynamoDB (they go to the private S3 bucket).
- Proxy image bytes through Lambda.
- Add a VPC, SNS/push infrastructure (notifications are iOS-local), GSIs, or extra tables.
- Use the deprecated `@google/generative-ai` SDK, or hardcode a model id.
- Commit secrets or a `.env`. Expand IAM to wildcards.
- Declare infra complete without a passing `cdk synth`.
- Skip the per-phase confirmation gate.
