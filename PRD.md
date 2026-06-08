# Product Requirements Document (PRD): Verdancy (MVP)

> **How to use with Claude Code:** Save as `PRD.md` in your project root and tell Claude Code:
> *"Read PRD.md and CLAUDE.md. Initialize an AWS CDK project in TypeScript and build the backend per Sections 3–5. Ask for my confirmation before each phase."*

This PRD covers the **backend**. The iOS (Swift) app is summarized in Section 6 and specced fully in a separate iOS PRD.

---

## 1. Overview & Architecture Principle

**Verdancy** is a premium, subscription-based iOS plant identification and care tracker. It ties the subscription to a real-world commitment: **10 trees planted when a user subscribes, plus 1 tree per in-app milestone reached.**

**Architecture principle — one source of truth, controlled costs:**
* **AWS owns everything user-facing and persistent:** identity, the AI proxy, the **structured user data** (garden, care schedule, growth-timeline entries, tree tally), and the **user image blobs**. One queryable, server-side source of truth you can support, restore, and (later) port to other platforms.
* **Images live in a private S3 bucket, accessed via presigned URLs, and are cached aggressively on-device.** The app uploads each image with a short-lived presigned `PUT` and downloads with a short-lived presigned `GET`; **image bytes never pass through Lambda.** Each image is downloaded roughly once per device and then served from the local cache, which is also the offline story. A structured record references its image by `image_ref` (the S3 object key).
* **Why not CloudKit:** CloudKit is free but (a) requires the user to be signed into iCloud and (b) permanently locks the image layer to Apple platforms. S3 keeps the door open for a future Android/web client and removes the iCloud dependency. The cost is small and controlled (see below).
* **Shared pixel-art sprites** (post-MVP) live in a **separate** S3 bucket + CloudFront, because a sprite is shared across all users of a species.
* The UX (Today dashboard, reminders, paywall) computes **on-device**.

**Cost:** Cognito, Lambda, API Gateway HTTP API, and DynamoDB are within free tier at MVP scale. User images are the only new variable: at ≤1MP (~250KB) each, 10k users × ~30 images ≈ 75 GB ≈ **~$1.70/month** storage; egress stays low because the app caches each image locally after one download and bytes bypass Lambda via presigned URLs. A lifecycle policy tiers cold objects to cheaper storage. The other variable cost is Gemini API usage, capped by a per-user quota (Section 5).

> **No more two-system seam.** Because records *and* images now both live on AWS, a new device restores both from the same backend — no placeholder gap waiting on a second sync system. Aggressive on-device caching is the cost control, not a separate storage backend.

---

## 2. Where each thing lives

| Concern | Lives in |
| --- | --- |
| Garden, care schedule, growth-timeline entries, profile, tree tally, **entitlement flag** | **AWS DynamoDB** (source of truth, synced via API) |
| Plant photos & growth-timeline photo bytes | **AWS S3** (private bucket, presigned URLs, referenced by `image_ref`); **cached on-device** |
| Shared pixel-art sprites (post-MVP) | **AWS S3 + CloudFront** (separate bucket) |
| Today dashboard, reminders, weather/season greeting | **On-device** (computed from data fetched from AWS) |
| Paywall UX + purchase | **RevenueCat SDK (on-device)** |
| **Server-side entitlement truth** | **AWS DynamoDB**, updated by a **RevenueCat webhook** (Section 4.6) |
| Sign-in identity | **AWS Cognito** (native Sign in with Apple + Google + email) |
| Identify / Diagnose (Gemini) | **AWS thin proxy Lambda** (protects key, enforces entitlement + quota, never stores images) |

---

## 3. AWS Footprint

1. **Amazon Cognito** — User Pool with **native Sign in with Apple** (federated identity provider) + Google + Email/Password. Outputs: Pool ID, Client ID, federation config. (Google OAuth secret + Apple key in Secrets Manager.)
   * **App Store note (Guideline 4.8):** because we offer Google sign-in, Apple **requires** Sign in with Apple. Use the native `ASAuthorizationController` flow on-device and federate the Apple identity token into Cognito — **not** the Hosted UI web redirect. Configure Cognito's Apple IdP accordingly.
2. **Amazon API Gateway (HTTP API)** with a **Cognito JWT authorizer** on all routes **except** the RevenueCat webhook (Section 4.6), which authenticates by shared secret.
3. **AWS Lambda** (Node.js 20.x) — a **single router Lambda** for the AI proxy + data CRUD (keeps it warm, simpler deploy), plus a small separate **webhook Lambda**.
4. **Amazon DynamoDB** — single table `VerdancyData`, on-demand, **no GSIs**. Source of truth for structured data.
5. **Amazon S3** — one **private** bucket `verdancy-user-images` (Block Public Access ON), presigned-URL access only, lifecycle policy to Intelligent-Tiering / IA for cold objects.
6. **Secrets Manager** — Gemini API key, RevenueCat webhook secret, Google/Apple credentials.
7. **(Post-MVP) S3 + CloudFront** — shared sprite store (separate bucket); not built for MVP.
8. **CloudWatch alarms** (cheap insurance) — Lambda error rate, and a billing/usage alarm to catch runaway Gemini spend.

No VPC. No push infrastructure (notifications are iOS-local).

---

## 4. Data, API & AI

### 4.1 DynamoDB — single table `VerdancyData`

PK = `PK` (String), SK = `SK` (String), Billing = PAY_PER_REQUEST. **No GSIs.** **TTL enabled on attribute `expires_at`** (used by the daily quota item).

| PK | SK | Attributes |
| --- | --- | --- |
| `USER#<sub>` | `METADATA` | `email`, `created_at`, `blocked` (bool), `entitlement_active` (bool), `entitlement_expires_at` (epoch, nullable), `free_ai_used` (int — lifetime free AI calls consumed), `trees_pledged` (int), `milestones` (string set) |
| `USER#<sub>` | `QUOTA#<YYYY-MM-DD>` | `count` (int), `expires_at` (epoch TTL ≈ 48h later) — **daily cost backstop; auto-deletes** |
| `USER#<sub>` | `PLANT#<plantId>` | `common_name`, `species` (normalized), `nickname`, `image_ref` (**S3 object key**), `toxicity`, `lighting_needs`, `fertilizer_info`, `confidence` (`High`/`Medium`/`Low`), `care` (map: water/fertilize/prune → `{cadence_days, last_done_at}`), `buddy_variant` (optional), `created_at` |
| `USER#<sub>` | `PHOTO#<plantId>#<ts>` | `image_ref` (**S3 key**), `taken_at`, `caption` |
| `SPECIES#<normalized-species>` | `BUDDY` | `status`, `sprite_url`, `style_version`, `created_at` *(post-MVP)* |

Access patterns (all direct, no index): profile (`USER#<sub>`/`METADATA`); today's quota (`USER#<sub>`/`QUOTA#<today>`); garden (`USER#<sub>` + `SK begins_with "PLANT#"`); a plant's photos (`SK begins_with "PHOTO#<plantId>#"`); species buddy (`SPECIES#<species>`/`BUDDY`).

### 4.2 S3 image keys & ownership

* **Key convention:** `image_ref` = `u/<sub>/p/<plantId>/<uuid>.jpg`. The user's `sub` is the first path segment.
* **Server generates the key** (the app never picks it) so the prefix always matches the authenticated caller.
* **Presign rule:** the API issues a presigned URL **only** after confirming the key's `<sub>` prefix equals the JWT `sub`. This is the S3 equivalent of object-level authorization.
* Presigned `PUT` and `GET` URLs are short-lived (≈5–15 min). The app caches downloaded bytes locally; URLs expiring is harmless because the cache, not S3, is the steady-state source.

### 4.3 Species normalization

`species` drives lookups and the buddy cache, so normalize once at identify time before persisting: lowercase, trim, collapse whitespace, drop cultivar text after a comma. All `SPECIES#` keys and `PLANT#.species` values use the normalized form; display uses `common_name`.

### 4.4 API (HTTP API, Cognito JWT authorizer on all routes except the webhook)

**Every handler derives `sub` from the verified JWT — never from the body. Every `{plantId}` route and every presigned-URL request verifies the resource belongs to the caller.**

| Route | Gate | Purpose |
| --- | --- | --- |
| `POST /users` | — | Idempotent profile upsert. App calls on first sign-in. |
| `POST /uploads` | — | Body `{kind:"plant"\|"photo", plantId?}` → server mints an `image_ref` under the caller's prefix and returns `{ image_ref, upload_url }` (presigned `PUT`). App uploads bytes directly to S3. |
| `POST /identify` | **entitlement + quota** | Body: resized image (base64). Proxy → Gemini structured output → care-card JSON. Image **never stored** by the proxy. |
| `POST /diagnose` | **entitlement + quota** | Same pattern → triage-plan JSON. |
| `POST /plants` | — | Save plant record (incl. `image_ref` from `POST /uploads`); seeds the `care` map. |
| `GET /plants` | — | List garden; each item includes a fresh **presigned download URL** for its `image_ref` (+ resolved buddy fields, post-MVP). |
| `POST /plants/{plantId}/care` | — | Body `{type:"water"\|"fertilize"\|"prune"}` → update `care.<type>.last_done_at`. |
| `DELETE /plants/{plantId}` | — | Remove plant + its photo entries **+ delete the corresponding S3 objects**. |
| `POST /plants/{plantId}/photos` | — | Add growth-timeline entry (`image_ref`, caption). *(deferrable)* |
| `GET /plants/{plantId}/photos` | — | List timeline entries, each with a presigned download URL. *(deferrable)* |
| `POST /milestones` | — | `{milestoneId}` → idempotent +1 tree (see 4.7). |
| `GET /me/trees` | — | `{ trees_pledged, milestones }` for display. |
| `POST /webhooks/revenuecat` | **shared-secret (no JWT)** | RevenueCat → updates `entitlement_active` / `entitlement_expires_at` (see 4.6). |

**Image handling for AI calls:** the app resizes each photo to ≤ ~1 MP on-device and sends the bytes inline to `/identify` or `/diagnose`; the proxy forwards to Gemini and **discards** them (no S3 write). The *kept* image is uploaded separately via `POST /uploads`, and its `image_ref` is passed when saving the plant.

### 4.5 Gemini calls (structured output) — tuned for accuracy & plant safety

SDK: **`@google/genai`** (the current GA `GoogleGenAI` client; the legacy `@google/generative-ai` is deprecated). Models via env: `IDENTIFY_MODEL_ID` and `DIAGNOSE_MODEL_ID`, both default **`gemini-3.5-flash`** (highest-accuracy Flash tier; do **not** downgrade to a Lite tier — care accuracy is a retention lever). Use `config: { responseMimeType: "application/json", responseSchema }`; wrap `JSON.parse` in try/catch.

* **Identify** (all required): `species`, `common_name`, `toxicity` (`High|Medium|Low|None`), `water_cadence_days` (int), `fertilize_cadence_days` (int), `lighting_needs`, `fertilizer_info`, **`confidence`** (`High|Medium|Low`).
* **Diagnose** (all required): `issue`, `likely_cause`, `severity` (`Critical|Moderate|Minor|Healthy`), `steps` (ordered array), **`confidence`** (`High|Medium|Low`).

**Accuracy & safety rules (baked into the prompt + handled in app):**
1. **Bias conservative on water.** When uncertain between watering frequencies, the model must return the **longer** interval. Overwatering / root rot is the most common cause of houseplant death — under-watering is far more recoverable. State this explicitly in the system prompt.
2. **No confident guesses.** If the plant is unidentifiable or `confidence` is `Low`, set `common_name` to `"Unknown Plant"` and **omit specific cadences** (return `water_cadence_days: null`). The app must **not** auto-apply a fake schedule; instead it prompts the user to retake a clearer photo and marks the care card tentative. (This replaces the old "default to water every 14 days" behavior, which was itself an overwatering risk.)
3. **Toxicity defaults safe.** If unknown, return `toxicity: "High"` (protect pets/kids by assuming the worst).
4. Ground all cadences in horticultural norms and prefer ranges where the species genuinely varies by environment.

### 4.6 Entitlement (server-side truth via RevenueCat webhook)

The paywall UX is RevenueCat-on-device, but **the server is the source of truth for whether AI calls are allowed**, so a bypassed client can't unlock the paid experience (only cost is capped — see Section 5).

* Configure RevenueCat `appUserID` = the Cognito `sub`, so webhook events map directly to a user.
* `POST /webhooks/revenuecat` (not behind the Cognito authorizer): verify the **shared secret** RevenueCat sends in the `Authorization` header (stored in Secrets Manager) before processing — reject otherwise.
* On `INITIAL_PURCHASE` / `RENEWAL` / `PRODUCT_CHANGE` → set `entitlement_active=true`, `entitlement_expires_at=<event expiry>`. On `EXPIRATION` / `CANCELLATION` / billing lapse → set `entitlement_active=false`.
* **First-purchase gap:** in the seconds between purchase and webhook arrival, a brand-new subscriber is still covered by their remaining free allowance, so there's no broken first experience. No extra logic needed for MVP.

### 4.7 Tree-planting commitment

* **Subscription trees (10):** displayed locally (RevenueCat SDK knows the user subscribed) and reconciled in aggregate against RevenueCat's data for actual planting. No per-tree backend write required.
* **Milestone trees (1 each):** reported via `POST /milestones`. Implement as **one atomic conditional `UpdateItem`** (not read-then-write):
  ```
  UpdateItem on USER#<sub>/METADATA:
    UpdateExpression:   ADD milestones :midSet, trees_pledged :one
    ConditionExpression: NOT contains(milestones, :mid)
    values: :midSet = {<milestoneId>}, :mid = <milestoneId>, :one = 1
  ```
  A duplicate fails the condition → the **entire** write is rejected, so `trees_pledged` increments exactly once even under concurrent double-submits. Milestones are TBD ids (first plant, tenth plant, 30-day streak, …).
* **Actual planting** is a partner integration (One Tree Planted / Ecologi / Eden), out of scope here; budget ~$1/tree (≈ $10/subscriber) into the annual price.

---

## 5. Security (MVP-essential)

1. **Object-level authorization (critical):** identity from the JWT only; scope all `USER#<sub>` keys and all S3 `u/<sub>/…` prefixes to the caller; verify ownership on every `{plantId}` route and **before issuing any presigned URL** → else `403`/`404`.
2. **Entitlement + quota (product gate + cost backstop):** on each AI call, **reserve before calling Gemini**:
   * Read `METADATA`; if `blocked` → `403`.
   * **Subscriber** (`entitlement_active=true`): atomically `ADD count :one` on `QUOTA#<today>` with `ConditionExpression attribute_not_exists(count) OR count < :SUBSCRIBER_DAILY_AI_LIMIT`; on failure → `429`. The date lives in the key, so day-rollover is automatic and race-free; the item TTLs away. **This is the hard cost cap** even if the client is compromised.
   * **Non-subscriber** (`entitlement_active` false/absent): atomically `ADD free_ai_used :one` on `METADATA` with `ConditionExpression free_ai_used < :FREE_AI_LIFETIME_LIMIT`; on failure → `402` (payment required → app shows paywall). This is the free-trial gate so non-payers get a taste, not the full product.
   * Server-side entitlement (4.6) means a bypassed paywall does **not** grant the subscriber experience; the free counter still gates it.
3. **Key protection:** Gemini key + webhook secret only in Secrets Manager; never in the app, never in logs.
4. **S3 hardening:** Block Public Access ON; presigned URLs only; TLS enforced via bucket policy; short URL expiry.
5. **Webhook surface:** verify the RevenueCat shared secret on every webhook call before any write; this is the only unauthenticated route.
6. **Least-privilege IAM:** the router Lambda gets only the DynamoDB actions it needs on the one table plus `s3:GetObject`/`PutObject`/`DeleteObject` scoped to the bucket; the webhook Lambda gets only `UpdateItem` on the table. No `*`.
7. **Cognito baseline:** email verification, strong password policy, sensible token expiry.
8. **Hygiene:** never log JWTs, images, secrets, or PII; clean JSON errors (`200/400/401/402/403/404/429/500`); CDK dynamic refs; no VPC.

---

## 6. On-device responsibilities (summary — full detail in the iOS PRD)

The 4-tab app (**Today** / **Smart Scan** / **My Oasis** / **Settings**); fetching garden + care data from the AWS API and computing the Today due-list locally; **uploading plant & timeline images to S3 via presigned `PUT`, then aggressively caching them locally** (download each image roughly once; the local cache is the offline source); on-device image resize before calling the proxy; handling low-confidence identify results by prompting for a clearer photo rather than applying a schedule; local-notification scheduling from cadences; RevenueCat SDK for the paywall + annual free trial; native Sign in with Apple; local tree-count display; dark mode, haptics, progressive onboarding; bundled buddy sprites (Appendix A).

---

## 7. Implementation Phases

**Prerequisites:** AWS CDK v2 + Node 20.x; AWS CLI configured; `cdk bootstrap`; Gemini API key; Google OAuth client + Apple Sign-In key; RevenueCat account + webhook secret.

**Phase 1 — Scaffold + Auth.** CDK TS project; Cognito with native Sign in with Apple (federated) + Google + email. *Accept:* native Apple sign-in yields a valid Cognito JWT.

**Phase 2 — Data + storage + API shells.** DynamoDB `VerdancyData` (TTL on `expires_at`); private S3 bucket (Block Public Access, lifecycle policy); HTTP API + Cognito JWT authorizer; `501` shells for all routes; webhook route wired with secret verification only. *Accept:* authed routes `401` without a token; webhook rejects a bad secret.

**Phase 3 — Logic.** Implement: the proxy (`/identify`, `/diagnose` with entitlement+quota and the accuracy/safety rules of 4.5); presigned uploads (`POST /uploads`) and download URLs in `GET /plants`; CRUD (`/users`, `/plants`, `/plants/{id}/care`, `DELETE` with S3 cascade, photos); species normalization; `/milestones`; `GET /me/trees`; the RevenueCat webhook (4.6). *Accept (document commands):*
* `/identify` → schema-valid care card incl. `confidence` (image not persisted); low-confidence input → `Unknown Plant` with `water_cadence_days: null`. `/diagnose` → ordered `steps`.
* `POST /uploads` → presigned `PUT` under the caller's prefix; uploading then `POST /plants` → plant appears in `GET /plants` with a working presigned download URL and seeded `care`.
* `care {type:"water"}` updates `last_done_at`; `DELETE` removes plant, its photos, **and** its S3 objects.
* **Quota/rollover:** subscriber over `SUBSCRIBER_DAILY_AI_LIMIT` → `429` (Gemini not called); a call the next calendar day succeeds (new `QUOTA#<date>` key). Non-subscriber over `FREE_AI_LIFETIME_LIMIT` → `402`. `blocked=true` → `403`.
* **Entitlement:** webhook `INITIAL_PURCHASE` flips `entitlement_active=true` and the user is then gated by the daily cap, not the free counter; `EXPIRATION` flips it back.
* **Auth checks:** user A on user B's plant → `403`/`404`; user A requesting a presigned URL for user B's `image_ref` → `403`.
* `POST /milestones` twice, same id → `trees_pledged` +1 once (single conditional write); `GET /me/trees` reflects it.

---

## Appendix A — Plant Buddy (Post-MVP)

> Build after MVP. A pixel-art "bud" companion per plant, revealed with a blossom animation; its expression reflects care state (derived on-device).

* **Per-species, not per-plant/per-user** — every monstera owner gets the same monstera bud (cohesive collection, near-zero marginal cost).
* **Bundle the curated common library in the app** — pre-generate and hand-review the top ~100–200 houseplants and ship the sprites inside the app binary. Most users get their bud instantly, offline, with no backend call.
* **Rare-species tail → separate S3 bucket + CloudFront (shared).** When a saved species isn't bundled, the app requests generation via a proxy route (same key-protection pattern as identify); the sprite is generated once, post-processed, written to the **sprite** bucket, served via **CloudFront**, and recorded on the `SPECIES#<species>/BUDDY` item. Any later user with that species gets the cached URL. Use a **separate** bucket from user images (shared/public-read-via-CDN vs. private per-user). Carry `style_version` to allow a full re-cache if the art is revamped.
* **Generation:** prompt = fixed style prefix + species clause + your **own** style-bible reference sprites (never a third-party artist's work), on a flat chroma background; post-process (chroma-key to transparent → nearest-neighbor downscale → quantize to the locked palette).
* **Moods, growth stages, reflections, backgrounds, share cards:** rendered **on-device** over the one transparent base sprite — no regeneration.
