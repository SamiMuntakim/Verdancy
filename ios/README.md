# Verdancy iOS

The SwiftUI client for Verdancy (see [`../iOS-PRD.md`](../iOS-PRD.md) for the spec and
[`../PRD.md`](../PRD.md) for the backend API contract). Authored on Windows, so **build on a Mac**.

## Get it building

```bash
brew install xcodegen
cd ios
xcodegen generate
open Verdancy.xcodeproj
```

Then in Xcode: select the `Verdancy` scheme + a simulator and run (⌘R).

### Before it runs for real

1. **Backend deployed** (Phase 2/3) and **Stage B (Sign in with Apple federation)** wired, so the app
   has a working Cognito user-pool client + hosted domain.
2. **`Verdancy/Config/AppConfig.swift`** — set `apiBaseURL` (the `HttpApiUrl` output) and the
   RevenueCat public SDK key.
3. **`Verdancy/Resources/amplifyconfiguration.json`** — copy `amplifyconfiguration.template.json`
   to `amplifyconfiguration.json` and fill in your Cognito pool id, app client id, region, and the
   hosted-UI domain. (The real file is gitignored.)
4. **Signing** — set your Team ID in `project.yml` (`DEVELOPMENT_TEAM`) and enable the **Sign in with
   Apple** capability (already declared in `Verdancy.entitlements`).

Until auth config is in place, the app runs against **`MockAuthService`** (and mock data) so the UI
is fully previewable/runnable — flip `AppConfig.useMockAuth` to `false` once Cognito is wired.

## Status

Built: project scaffold + foundation (models, `APIClient`, `AuthService`, design system,
`GardenStore`/`ImageCache`/`SnapshotStore`/`ImagePipeline`), and iOS-PRD **Phases 1–5** in substance:

- **1 Shell + Auth** — onboarding → Sign in with Apple, 4-tab shell, `POST /users`.
- **2 Core loop** — Smart Scan (identify/diagnose, camera + library), §6 low-confidence handling,
  save flow (`/uploads` → S3 → `/plants`), the dormant bud.
- **3 Garden/Today/streaks** — My Oasis + detail + delete, on-device due-list, swipe-to-complete,
  care streak, local notifications, snapshot offline.
- **4 Monetization + bloom** — onboarding, hard paywall, RevenueCat (`EntitlementService`), the
  seed→bloom reveal, tree-impact display, Settings.
- **5 Referral/sharing** — milestone reporting + tree-earned celebration, `ShareLink` invites.

Also closed (the remaining buildable §3/§13 items): **account deletion** (`DELETE /users` →
sign-out), **appearance** (system/light/dark, persisted), **Diagnose gated subscriber-only**,
**plant edit** (`PATCH /plants/{id}`), and the **growth timeline** (photos list + add).

**Still to do (not codeable on Windows):** bundled bud sprite **art assets**, **RevenueCat offering
config** in App Store Connect, and a **Mac/Xcode compile pass** (RevenueCat/Amplify API exactness
unverified).
