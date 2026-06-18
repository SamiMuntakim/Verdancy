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

Built so far: project scaffold, the foundation (models, `APIClient`, `AuthService`), the design
system, and **Phase 1 (Shell + Auth)** plus the four tab pages. Phases 2–5 (core scan loop, garden +
Today + streaks, monetization + bloom, referral) follow the iOS-PRD §12 plan.
