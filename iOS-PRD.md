# Product Requirements Document (PRD): Verdancy iOS App (MVP)

> **How to use with Claude Code:** Save as `iOS-PRD.md` in your iOS project root alongside a `CLAUDE.md`. Pair it with the backend `PRD.md` (the API contract). Tell Claude Code:
> *"Read iOS-PRD.md and CLAUDE.md. Scaffold the SwiftUI app and build per the phases in Section 12. Ask for my confirmation before each phase."*

This is the **iOS app**. The backend (AWS) is specced in `PRD.md`; this document consumes that API and owns everything on-device.

---

## 1. Overview & Principles

**Verdancy** is a premium, subscription iOS plant identification and care tracker. It makes plant care effortless and rewarding, and ties that to a real-world good (trees planted).

**On-device principles:**
* **The API is the source of truth.** The app fetches the garden, care schedule, and tree tally from AWS and renders them; it does not maintain a competing local database. A lightweight on-disk **JSON snapshot** of the last fetch enables instant cold-start and offline viewing.
* **Today is computed locally.** The "what's due" list is derived on-device from each plant's cadence + `last_done_at` — no server call needed to know what to water.
* **Images: presigned S3 + aggressive local cache.** Upload via presigned `PUT`, download via presigned `GET`, then cache bytes on disk keyed by `image_ref`. Each image downloads roughly once; the local cache is the offline source. (Presigned URLs rotate; the cache key is the stable `image_ref`.)
* **Entitlement is RevenueCat on-device** for the paywall UX; the server independently enforces access, so a cracked client only hits the same quota, never a free unlock.
* **Monetization principle (decided — see §7):** a **hard paywall after one free "aha" scan** drives conversion (~5x freemium with near-identical retention, per RevenueCat's 2026 benchmarks); the **tree-planting commitment + the collectible Plant Bud + care streaks** are the *retention and word-of-mouth* engine, since AI identification itself is a commodity every competitor has.
* **Native and minimal.** SwiftUI, URLSession, as few dependencies as possible.

## 2. Tech stack (decided)

| Concern | Choice |
| --- | --- |
| UI | **SwiftUI**, minimum **iOS 17.0** |
| State | **`@Observable`** (Observation framework), MVVM-lite: views + view models + one `APIClient` + one `AuthService` |
| Networking | **URLSession** (no third-party HTTP library) |
| Auth | **Native Sign in with Apple** (`AuthenticationServices`) federated into Cognito, via **AWS Amplify Swift (Auth only)** for the Cognito token lifecycle, behind an `AuthService` protocol so it's swappable |
| Paywall / entitlement | **RevenueCat** (`purchases-ios`) |
| Image resize | **ImageIO / Core Graphics** downsample to ≤ ~1 MP before any upload or AI call |
| Local persistence | **JSON snapshot on disk** (garden + trees) + a **custom on-disk image cache** keyed by `image_ref`. No SwiftData/Core Data for MVP. |
| Notifications | **UserNotifications** (local only) |

**Dependency count for MVP: two** (RevenueCat + Amplify Auth). Everything else is first-party.

**MVP sign-in scope:** **Apple only.** The backend supports Google + email too, but the app surfaces only Sign in with Apple in v1 for one clean auth path. Google/email are a fast-follow.

**Plant Bud scope (important):** because the bud reveal is now a load-bearing **conversion** mechanic (§8–§9), a **minimal** version of the bud ships in MVP — the seed/closed-bud teaser, the bloom animation, a small starter set of buds for the most common houseplants, and a generic fallback bud. The **full** per-species library (~100–200 hand-reviewed sprites), rich mood states, growth stages, and the rare-species generation pipeline remain **post-MVP** (backend Appendix A).

**App Store economics:** enroll in **Apple's Small Business Program** (you keep 85% while under $1M/yr). Every price/margin figure in §7 and §10 assumes this.

---

## 3. App structure — 4 tabs

A `TabView` with four tabs. Auth gate in front; onboarding + paywall layered on first launch (§8).

### 3.1 Today
The home tab. Answers "what does my plant need right now?"
* **Greeting header** — time-of-day / season greeting + the **care streak** (§11) + the **tree-impact count** (§10). (Weather-aware greeting is post-MVP.)
* **Due list** — computed locally: for each plant and each care type (`water`/`fertilize`/`prune`) with a cadence, `next_due = last_done_at + cadence_days`; show items where `next_due ≤ today`, overdue-first. Each row: plant thumbnail, name, task, "overdue by N days" / "due today."
* **Swipe-to-complete** → `POST /plants/{plantId}/care {type}` → optimistic update of `last_done_at = now` → recompute → success haptic, advance streak. Reconcile/rollback on failure.
* **Empty state** → nudge to scan a first plant (routes to Smart Scan).

### 3.2 Smart Scan
The core magic loop. Two modes via a segmented control: **Identify** and **Diagnose**.
* **Capture** — camera or photo-library picker → downsample to ≤1MP.
* **Identify flow:** `POST /identify` (inline image bytes) → care card. Handle the result by confidence (§6). On the **very first scan**, this is the free "aha" — it also **plants the seed** (§8–§9): the saved plant gets a **dormant closed bud**.
* **Diagnose flow:** `POST /diagnose` → triage card: `issue`, `likely_cause`, `severity` (color-coded), ordered `steps`. (Diagnose is subscriber-only; does not save a plant.)
* **Save flow (identify, on accept):** "name your plant" step (sets `nickname`) → `POST /uploads` to mint an `image_ref` + presigned `PUT` → upload the photo directly to S3 → `POST /plants` with `image_ref` + care fields → cache image locally → land on the plant's detail showing its bud (dormant until subscribed; bloomed if subscribed).
* **Gate handling:** `402` (free scan exhausted) → present paywall (§8). `429` (subscriber daily cap) → friendly "you've scanned a lot today" message.

### 3.3 My Oasis
The garden / collection.
* **Grid** of plants from `GET /plants`, each a thumbnail (presigned URL → cached by `image_ref`) + name + its **bud** (dormant closed bud if the user isn't subscribed; bloomed buddy if they are). Pull-to-refresh; renders from the disk snapshot instantly, then refreshes.
* **Plant detail** (tap a plant):
  * Care schedule (water / fertilize / prune cadences with next-due dates) + mark-done.
  * The plant's **bud** (dormant or bloomed), its mood reflecting care state once bloomed (post-MVP depth).
  * Toxicity, lighting needs, fertilizer info.
  * **Growth timeline** — photos from `GET /plants/{id}/photos`; add via `POST /uploads` → `POST /plants/{id}/photos` *(deferrable within MVP)*.
  * **Delete plant** → confirm → `DELETE /plants/{plantId}` (cascades photos + S3 objects server-side).

### 3.4 Settings
* **Account** — signed-in identity; **Sign out**; **Delete account** (required — see §13).
* **Subscription** — current status; **Restore purchases**; **Manage subscription** (RevenueCat / App Store).
* **Your impact** — total trees + milestone breakdown + link to the public tree counter (§10).
* **Invite friends** — the tree-based referral loop (§10).
* **Notifications** — master toggle + permission prompt.
* **Appearance** — system / light / dark.
* **About / Legal** — privacy policy, terms, support contact, version.

---

## 4. Networking & data flow

* **`APIClient`** — async/await over URLSession. Attaches the Cognito JWT (`Authorization: Bearer`) from `AuthService` to every call; refreshes on `401` and retries once. Decodes typed `Codable` models. Maps status codes to typed errors (`.paywall` for `402`, `.rateLimited` for `429`, `.unauthorized`, `.notFound`, `.server`).
* **Models** mirror the backend contract: `Plant` (incl. `care` map, `confidence`, presigned `image_url`), `CareCard` (identify result), `DiagnosisCard`, `TreeStatus`.
* **Snapshot cache** — after a successful `GET /plants` and `GET /me/trees`, persist a JSON snapshot to Documents. On launch, hydrate UI from the snapshot immediately, then refresh in the background ("stale-while-revalidate").
* **Image cache** — `ImageCache` stores downloaded bytes on disk keyed by `sha256(image_ref)`; cache hit → return; miss → fetch presigned URL, store, return.

## 5. Image pipeline

1. Pick/capture → **downsample to ≤ ~1 MP** (ImageIO `CGImageSourceCreateThumbnailAtIndex`), JPEG ~0.8.
2. **AI calls** (`/identify`, `/diagnose`): send downsampled bytes inline; server forwards to Gemini and discards.
3. **Kept images** (saved plant, timeline): `POST /uploads` → presigned `PUT` → upload **directly to S3** (never through your API), then cache locally under `image_ref`.
4. **Display**: resolve `image_ref` via the cache; only hit S3 (presigned `GET`) on a miss.

## 6. Accuracy & safety handling (critical for retention)

The server biases conservative and returns a `confidence` field; the app must honor it so we never hand a user a plant-killing schedule.

* **`confidence == High`** → save normally, apply the schedule.
* **`confidence == Low` OR `common_name == "Unknown Plant"`** (server returns `water_cadence_days: null`) → **do not auto-apply a schedule.** Show "We're not sure about this one — try a clearer, well-lit photo of the leaves," offer **Retake**, and allow saving as *Unidentified* with no cadence (no fake reminders). A retake consumes free-scan headroom, which is why the free allowance is 2–3, not 1 (§7).
* **Toxicity** — if `High`, surface a clear pet/child-safety note on the card and plant detail.
* *(Optional, pending the backend curated-care decision)* if the care card includes `source == "curated"`, show a small **"vet-reviewed"** badge. Additive; no MVP dependency.

---

## 7. Monetization model (decided)

Grounded in RevenueCat's 2026 benchmarks (75k+ apps) and the plant-app category.

**Model: hard paywall after one free scan.** Hard paywalls convert ~5x better than freemium (≈10.7% vs 2.1% download-to-paid by day 35) with **near-identical** year-one retention, and ~8x higher revenue per install. The category bears this out — PictureThis (aggressive hard paywall) clears ~$5M/mo on US iOS; Planta (generous freemium, "core should be free" complaints) does ~$300k/mo. So: **not freemium.** The one optimization over competitors like Greg (whose paywall hits *before* any value): let the **first scan through free** so the user gets a Day-0 "aha" before the wall — and that scan also plants their bud (§8–§9).

**Pricing:**
* **Annual — $39.99/yr — the default and the hero option.** Anchored to the category leader; the tree commitment justifies parity. Annual subs renew best and keep the tree economics safe.
* **Monthly — $7.99/mo — the anchor** that makes annual look obvious. De-emphasized.
* **No lifetime.** Your tree pledge + ongoing Gemini cost is *recurring* COGS; a lifetime buyer goes underwater. (Greg can do lifetime because their marginal cost is ~0; yours isn't.)
* **7-day free trial** (category standard; long enough for the first watering reminders to fire and the habit to begin). Most trial cancellations happen on **Day 0**, so the onboarding aha + the bloom reveal (§8) are the conversion-critical moments.

**Free allowance:** set the backend `FREE_AI_LIFETIME_LIMIT` to **~2–3 identifies** — messaged to the user as "your first scan is free," with the extra 1–2 as silent retake headroom for a low-confidence first photo (§6). Diagnose is subscriber-only.

**Margin guardrails (the tree commitment is real money):**
* **Stagger the 10 trees** across the first subscribed year rather than planting all on day one (backend §4.7) — protects against trial refunds and fast monthly churn at ~$1/tree.
* **Milestone trees are a paid-subscriber benefit** (backend §4.7) — a free user's one saved plant earns no real tree.
* Bias hard toward annual, where every figure above is comfortably profitable after Apple's 15%.

---

## 8. Onboarding & paywall flow (the seed → bloom mechanic)

The exact first-run sequence. Two distinct bud states — **dormant closed bud** (before subscribing) and **bloomed buddy** (after) — are the spine of this flow.

1. **Light onboarding** — 2–3 screens on the promise (identify, care reminders, real trees), then **Sign in with Apple** → `POST /users`. Don't front-load permission prompts. Keep any personalization quiz short.
2. **First free scan — "plant your seed."** Route straight into Smart Scan. The user scans a real plant, gets the care card (the aha), names and saves it. Saving it **plants a seed**: the new plant shows a **dormant closed bud** — visibly *theirs*, clearly "forming," not yet open. This is the open loop.
3. **Hard paywall.** Continuing past the first scan (a second scan, diagnose, reminders, or tapping the dormant bud) hits the wall. The paywall:
   * Leads with the dual value — *keep your plants alive* + *plant 10 real trees* — **not** with the bud as the primary CTA (the bud is the emotional cherry, not the whole pitch).
   * Shows the dormant bud with "Subscribe to help it bloom" as a secondary, delightful reason.
   * Presents the **7-day free trial**, **annual as the hero**, monthly secondary; social proof; restore-purchases link.
   * Is driven by RevenueCat offerings.
4. **Subscribe → BLOOM.** On the subscribe/trial-start confirmation, fire the **bloom animation immediately**: the dormant bud opens into the buddy. This is the Day-0 post-purchase payoff that fights first-session cancellation (the #1 churn moment) and starts the ongoing buddy relationship.
5. **Post-purchase** — RevenueCat updates entitlement locally; the server webhook catches up within seconds (the remaining free allowance covers the gap, so nothing breaks). Now unlocked: unlimited identify, diagnose, schedules + reminders, streaks, and blooming buds.

**Framing rule (non-negotiable):** the bud is always presented as *"look what's growing for you,"* never *"pay or it stays a seed"* punitively. The plant/bud never "suffers." A wholesome, plant-real-trees brand loses more from feeling manipulative than a generic utility would — design for delight, not hostage.

---

## 9. The Plant Bud — states & MVP scope

A pixel-art **bud** companion, one per plant. The reveal mechanic is core to conversion (§8) and the ongoing buddy is core to retention (§11).

**States:**
* **Seed / dormant closed bud** — shown the moment a plant is saved while the user is **not** subscribed. Static, "forming," the locked teaser.
* **Bloom (reveal)** — the one-time animation that fires on subscribe, opening the bud into the buddy.
* **Bloomed buddy** — the resting companion shown on the plant card/detail once subscribed.
* **Mood** *(post-MVP depth)* — the bloomed buddy's expression reflects care state (happy when on-schedule, droopy when overdue), rendered on-device over the one base sprite.

**In MVP:** the seed/dormant state, the bloom animation, a **small curated starter set** of buds for the most common first-scan houseplants (e.g. the top ~10–20: pothos, snake plant, monstera, aloe, spider plant, ZZ, peace lily…), and a **generic fallback bud** for everything else. This is enough to make the reveal land without the full library.

**Post-MVP (backend Appendix A):** the full ~100–200 per-species hand-reviewed library, the rare-species S3/CloudFront generation pipeline, rich mood/growth states, share cards.

**Edge case:** a first scan of a rare species with no bundled bud uses the generic fallback (still charming). Steer the "scan to start" prompt toward common houseplants so the first reveal is strong.

**Keep the two growth metaphors distinct:** the pixel **bud** is the per-plant *companion* (lives in the app); the real **tree** is the *cause* (planted in the world). Make sure the UI never lets users conflate "my bud bloomed" with "a real tree was planted" — unless you deliberately link them, which should be a choice, not an accident.

---

## 10. Trees & referral loop

The trees are the retention + virality engine, not the conversion lever (§7). They must be **provably real** — vague "we plant trees" reads as greenwashing.

**Display:**
* **Total** = (paid subscriber ? **10** : 0) + `trees_pledged` from `GET /me/trees` (milestone trees). The 10 is known locally via RevenueCat entitlement; milestones come from the server.
* Non-subscribers see the count aspirationally ("Subscribe to plant your first 10 trees").
* Celebrate each newly earned tree with a small animation + haptic — a natural sharing moment.

**Credibility (Ecosia's lesson):** ship a **public, real-time tree counter** and **name the planting partner** (One Tree Planted / Eden). "147,302 trees planted, verified by [partner]" is the asset; a number with no provenance is not.

**Milestone trees (client-detected, reported idempotently)** via `POST /milestones {milestoneId}` (server dedupes + gates on entitlement). **MVP milestones (count-based):** `first_plant`, `fifth_plant`, `tenth_plant`. Streak-based milestones are post-MVP.

**Referral via trees, not discounts.** This deliberately avoids the classic referral failure (a "free month" reward does nothing for evangelists who are *already* subscribers). Instead: **"Invite a friend — we plant a tree for both of you."** It's values-aligned, motivates subscribers and free users equally, costs ~$1 instead of eroding margin, and turns your most engaged users into a growth channel. Surface it in Settings and after sharing moments (a new tree, a bloom, a growth-timeline update). *(Needs a backend referral-attribution endpoint — see §13.)*

---

## 11. Streaks & retention

AI ID is a commodity; **retention is the moat.** The Duolingo playbook applies: streaks make users meaningfully more likely to return daily, and character attachment compounds it.

* **Care streak** — consecutive days with all due tasks completed; shown in the Today header. Advancing it on swipe-to-complete is the habit loop's reward.
* **The bloomed buddy as your "Duo"** — the per-plant companion whose mood reflects care is the emotional hook that makes the daily open feel like tending something alive.
* **Built-in sharing moments** — tree milestones, bud blooms, and growth timelines are inherently shareable; expose share affordances at those moments rather than via arbitrary notifications.
* **Avoid dark patterns** — gamify for empowerment, not guilt; the buddy/plant is never shamed or "harmed" to coerce engagement.

(MVP ships the care streak + buddy + share affordances; leaderboards and richer gamification are post-MVP.)

---

## 12. Implementation phases

**Prerequisites:** Xcode; Apple Developer account with Sign in with Apple; the deployed backend (Cognito IDs, API base URL); RevenueCat SDK key + configured offerings (annual hero + monthly); the starter bud sprites + bloom animation asset.

**Phase 1 — Shell + Auth.** SwiftUI app, `TabView` with four placeholder tabs, `AuthService` (Sign in with Apple → Cognito via Amplify), `APIClient` with JWT attach + refresh, `POST /users` on first sign-in. *Accept:* sign in with Apple, land on the tab bar, an authed `GET /plants` returns 200 (empty).

**Phase 2 — Core loop + the seed.** Capture + downsample, Identify + Diagnose, confidence handling (§6), the save flow (`/uploads` → S3 → `/plants`), image cache, and the **dormant closed-bud state** on a saved plant. *Accept:* scan a real plant → care card → name + save → it persists and reappears on relaunch with its photo and a dormant bud; a low-confidence result creates no fake schedule.

**Phase 3 — Garden, care, Today & streaks.** My Oasis grid + plant detail + delete; Today due-list computed locally; swipe-to-complete (`/care`) with optimistic update; **care streak**; snapshot cache + offline view; local notifications from cadences (permission requested after the first plant; reschedule on completion and launch). *Accept:* completing a task updates Today, advances the streak, and schedules the next reminder; the garden loads instantly offline.

**Phase 4 — Monetization + the bloom.** Onboarding, the **hard paywall after the free scan**, RevenueCat trial + annual-hero pricing, the **bloom reveal on subscribe**, the starter bud set + generic fallback, tree-impact display (with staggered-planting/subscriber-gated semantics), Settings (incl. restore + account deletion), dark mode, haptics, empty states. *Accept:* free scan exhausts → paywall → subscribe → **bud blooms** and scanning resumes; trees display correctly; account deletion removes the account and signs out.

**Phase 5 — Referral & sharing polish.** Tree-based referral ("invite a friend, plant a tree for both"), share affordances on blooms/milestones/timelines, public tree-counter link. *Accept:* an invite drives the referral flow end-to-end; sharing moments expose share sheets.

---

## 13. API dependencies & gaps to close

Routes consumed: `POST /users`, `POST /uploads`, `POST /identify`, `POST /diagnose`, `POST /plants`, `GET /plants`, `POST /plants/{id}/care`, `DELETE /plants/{id}`, photos routes, `POST /milestones`, `GET /me/trees`.

**Backend items this monetization model creates/requires:**
1. **`DELETE /users` (account deletion)** — **App Store Guideline 5.1.1(v) makes in-app account deletion mandatory.** Must delete the user's DynamoDB items + S3 objects. Required before submission.
2. **`PATCH /plants/{plantId}` (edit)** — rename / adjust a cadence after saving. Deferrable for MVP (nickname set at save, cadences from identify), but expected in a premium care app.
3. **Referral attribution** — a lightweight endpoint/flow to credit "invite a friend → a tree for both" (e.g. an invite code that, on a friend's first paid conversion, records a milestone-style tree for the inviter). Needed for §10's loop; Phase 5.
4. **Config values (already env vars in the backend):** `FREE_AI_LIFETIME_LIMIT ≈ 2–3`; keep `SUBSCRIBER_DAILY_AI_LIMIT` high enough that no real user hits it. Tree staggering + subscriber-gated milestones are specified in backend §4.7.

---

## 14. Design direction (light — will evolve)

Premium, calm, plant-forward. A **green-forward palette with a warm terracotta accent**, generous whitespace, soft cards, and satisfying micro-interactions (haptics on care completion, the bud bloom, and tree-earned moments). Full **dark mode** from day one. The **pixel-art buds** are now part of MVP (minimal set; §9) and are central to the app's personality — design the plant cards so the dormant-bud and bloomed-buddy states, and later the full per-species library, slot in cleanly. Keep MVP visuals clean and restrained — let the photos, the green, and the bud carry it.
