# CLAUDE.md — Verdancy Backend

This file is the operating manual for working in this repo. **`PRD.md` is the source of truth for *what* to build** (data model, routes, phases, acceptance criteria); this file is *how* to work and the rules you must not break. Read both before starting.

Verdancy is a subscription iOS plant ID + care app. This repo holds the **AWS CDK (TypeScript) backend** — Cognito, an HTTP API, Lambda handlers, DynamoDB, a private S3 image bucket, and (for the Plant Buddy) a shared sprite bucket fronted by CloudFront. The **iOS app (Swift/SwiftUI) also lives in this repo under `ios/`** (governed by its own `ios/CLAUDE.md` + `iOS-PRD.md`); this file governs the backend.

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
lib/verdancy-stack.ts    # the single stack (Cognito, HTTP API, Lambdas, DynamoDB, S3, sprite bucket + CloudFront)
src/handlers/router.ts   # main router Lambda (AI proxy + CRUD)
src/handlers/webhook.ts  # RevenueCat webhook Lambda (secret-verified, no JWT)
src/handlers/auth.ts     # native Apple/Google token exchange → Cognito tokens (POST /auth/{apple,google})
src/handlers/buddy.ts    # Plant Buddy sprite generation (POST /buddy) — heavier, own Lambda (Appendix A)
src/lib/                 # shared: dynamo, gemini, buddy image pipeline, auth/ownership helpers, error shapes
src/assets/              # bundled style-reference sheet for buddy generation (esbuild-bundled)
test/                    # jest
```

---

## HARD INVARIANTS — never violate these

These are the regression-prone rules. If a change would break one, stop and flag it.

1. **Identity comes only from the verified JWT `sub`.** Never read user identity from the request body, query string, or a client-supplied field.
2. **Object-level authorization on everything.** Every `{plantId}` route and every presigned-URL request must confirm the resource belongs to the caller (S3 keys live under `u/<sub>/…`) → else `403`/`404`. A user must never touch another user's plant, photo, or image.
3. **Reserve quota BEFORE calling Gemini.** Never call Gemini until the reservation write succeeds.
   - Subscriber (`entitlement_active=true`): atomic `ADD count :one` on `QUOTA#<today>` with condition `attribute_not_exists(count) OR count < :SUBSCRIBER_DAILY_AI_LIMIT` → `429` on failure.
   - Non-subscriber **identify**: atomic `ADD count :one` on the same date-keyed `QUOTA#<today>` with condition `< :FREE_DAILY_AI_LIMIT` (≈2, daily — **not** lifetime) → `402` on failure.
   - **Care plan** (`POST /plants/{id}/care-plan`) is **subscriber-only**: `402` for non-subscribers **before any Gemini call** (no credits spent), then reserve the subscriber daily quota. Identify is free; the environment-tailored care plan is the premium value.
4. **Daily quota is date-keyed with TTL.** Both the subscriber cap and the non-subscriber free identify allowance use a `QUOTA#<YYYY-MM-DD>` item with an `expires_at` TTL. Never store a mutable rolling counter + date on the METADATA item (that path has a rollover race).
5. **Milestone increment is ONE atomic conditional `UpdateItem`** (`ADD milestones :midSet, trees_pledged :one` with `ConditionExpression: NOT contains(milestones, :mid)`). Never read-then-write — it double-counts on concurrent submits.
6. **Image bytes never pass through Lambda** *(user photos)*. Uploads and downloads use presigned S3 URLs only; Lambda issues the URLs, never proxies the bytes. The inline bytes sent to `/identify` and `/diagnose` are forwarded to Gemini and immediately discarded — never written to S3. **Narrow exception — Plant Buddy:** `POST /buddy` *does* handle image bytes end-to-end (Gemini image → chroma-key/downscale → write the small PNG to the shared **sprite** bucket). A bud is a tiny, shared, non-user asset — this exception never applies to user photos.
7. **The server generates S3 keys** under `u/<sub>/p/<plantId>/<uuid>.jpg`. The app never supplies or chooses a key.
8. **Never emit a fake care schedule.** `identify` returns identity only (name + `taxonomy` + `toxicity` + `confidence`, no cadences); on low `confidence` or an unidentifiable plant: `common_name = "Unknown Plant"`, `taxonomy = null`, `toxicity = "High"`. Cadences come from the **care plan**, whose system prompt biases conservative: when genuinely uncertain between watering intervals, return the **longer** one — overwatering is the top plant killer and the top churn risk.
9. **Entitlement truth is server-side** (`entitlement_active` in DynamoDB, set by the RevenueCat webhook). Never gate AI access on a client-asserted subscription status.
10. **Secrets only from Secrets Manager.** Never hardcode the Gemini key or webhook secret. Never log JWTs, images, secrets, or PII.
11. **One DynamoDB table, no GSIs.** Don't add a GSI or a second table without explicit approval — the access patterns don't need one.
12. **Least-privilege IAM.** Scope each Lambda's actions to the one table (and the image-bucket prefix for the router); never use `*` on actions or resources.

---

## Stack-specific facts (do not rely on training data for these)

- **Gemini SDK is `@google/genai`** (`import { GoogleGenAI } from "@google/genai"`). The legacy `@google/generative-ai` is **deprecated/EOL — do not use it.**
- **Models come from env** (`IDENTIFY_MODEL_ID`, `DIAGNOSE_MODEL_ID`), default **`gemini-3.5-flash`**. Do **not** downgrade to a Lite tier — care accuracy is a retention lever. Structured output goes in `config: { responseMimeType: "application/json", responseSchema }`; wrap `JSON.parse` in try/catch.
- **Plant Buddy** (Appendix A of `PRD.md`): shared per **normalized species**, generated once via `POST /buddy` and served from a **separate** sprite bucket via CloudFront. Image model `BUDDY_MODEL_ID` defaults to **`gemini-3.1-flash-image`** (full Nano Banana 2 — the Lite tier drew literal plants instead of the chibi mascot); pinned to a **stable id**, not a `-latest` alias (which could silently drift the art). Generation is anchored to a **single-bud** style-reference image passed as an input image part (a multi-bud sheet made the model copy the row layout); the prompt forces a round, frame-filling chibi and forbids realistic/tall plants. Pipeline = chroma-key → de-fringe residual magenta → **crop to content** → **fit-centered** at 64px → PNG (**no palette snap** — the reference art is the house style). Cache hits require a matching `STYLE_VERSION` (currently **3**), so bumping it forces a full re-generate; generation is claimed with one atomic conditional write (concurrent callers → `202`). Image call is `@google/genai` `generateContent` with `responseModalities: [Modality.IMAGE]` (returns JPEG or PNG).
- **Cognito uses native Sign in with Apple** as a federated IdP (+ Google + email), **not** the Hosted UI web redirect. App Store Guideline 4.8 requires Sign in with Apple because we offer Google.
- **API Gateway is the HTTP API** (not REST) with a Cognito JWT authorizer on all routes **except** `POST /webhooks/revenuecat` (secret-verified).
- **Lambda runtime: Node.js 20.x.**
- **RevenueCat `appUserID` = Cognito `sub`** so webhook events map to a user.

## Environment variables

`TABLE_NAME`, `USER_IMAGE_BUCKET`, `GEMINI_API_KEY` (Secrets Manager), `REVENUECAT_WEBHOOK_SECRET` (Secrets Manager), `IDENTIFY_MODEL_ID`, `DIAGNOSE_MODEL_ID`, `CARE_PLAN_MODEL_ID` (defaults to identify model), `BUDDY_MODEL_ID` (Plant Buddy image model; default `gemini-3.1-flash-image`), `SPRITE_BUCKET` + `SPRITE_CDN_BASE` (buddy Lambda only), `FREE_DAILY_AI_LIMIT` (free identifies per day, ≈2), `SUBSCRIBER_DAILY_AI_LIMIT`.

## Error shapes

Return clean JSON errors with these statuses only: `200 / 400 / 401 / 402 / 403 / 404 / 429 / 500`. `402` = daily free identify exhausted **or** care plan requested by a non-subscriber (client shows paywall). `429` = subscriber daily cap hit.

---

## Do NOT

- Store user images in CloudKit or DynamoDB (they go to the private S3 bucket).
- Proxy image bytes through Lambda.
- Add a VPC, SNS/push infrastructure (notifications are iOS-local), GSIs, or extra tables.
- Use the deprecated `@google/generative-ai` SDK, or hardcode a model id.
- Commit secrets or a `.env`. Expand IAM to wildcards.
- Declare infra complete without a passing `cdk synth`.
- Skip the per-phase confirmation gate.
