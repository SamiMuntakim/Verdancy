# CLAUDE.md — Verdancy iOS

Operating manual for the Verdancy iOS app. **`iOS-PRD.md` (repo root) is the source of truth for
*what* to build**; the backend `PRD.md` is the API contract. This file is *how* to work.

> **Build environment:** this is a SwiftUI app — it compiles and runs **only on macOS with Xcode**.
> It is being authored on Windows, so the Swift sources here are **carefully written but not
> compiler-verified.** A Mac/Xcode pass is required.

## Project setup

```bash
brew install xcodegen        # one-time
cd ios && xcodegen generate  # regenerate Verdancy.xcodeproj after changing project.yml or adding files
open Verdancy.xcodeproj      # build/run from Xcode (Cmd-R)
```

The `.xcodeproj` is generated and gitignored; `project.yml` is the source of truth. Add a new Swift
file under `Verdancy/` and re-run `xcodegen generate` (sources are folder-globbed).

## Architecture (decided — iOS-PRD §2)

- **SwiftUI**, min **iOS 17**. State via **`@Observable`** (Observation), MVVM-lite: views + view
  models + one `APIClient` + one `AuthService`.
- **Networking:** `URLSession` only (no third-party HTTP lib). `APIClient` attaches the Cognito JWT,
  refreshes on `401` + retries once, decodes typed `Codable`, maps status → typed `APIError`.
- **Auth:** native Sign in with Apple federated into Cognito via **Amplify Swift (Auth only)**,
  behind the `AuthService` protocol so it's swappable. A `MockAuthService` backs previews/dev.
- **Two dependencies only:** RevenueCat + Amplify Auth. Everything else first-party.
- **Persistence:** JSON snapshot on disk (garden + trees) + a custom on-disk image cache keyed by
  `image_ref`. No SwiftData/Core Data.

## Folder layout

```
Verdancy/
  App/            VerdancyApp (@main), RootView (auth gate), AppModel
  Config/         AppConfig (API base URL, RevenueCat key)
  DesignSystem/   Theme (green + terracotta, dark mode), Haptics
  Models/         Codable models mirroring the backend contract
  Networking/     APIClient, Endpoints, APIError
  Auth/           AuthService protocol, AmplifyAuthService, MockAuthService
  Services/       ImagePipeline, ImageCache, SnapshotStore, Notifications, Entitlements
  Features/       Today, SmartScan, MyOasis, Settings, Onboarding, Buddy
  Resources/      Info.plist, entitlements, Assets, amplify config
```

## Invariants (don't break these)

1. **Honor `confidence` (iOS-PRD §6).** `Low` or `common_name == "Unknown Plant"`
   (`water_cadence_days == null`) → never auto-apply a schedule or fake reminders; prompt for a
   clearer photo, allow saving as *Unidentified*.
2. **Identity from the token only.** Never send a user id in a body; the JWT `sub` is identity.
3. **Images via presigned S3, never through the API.** Upload with the presigned `PUT`, download
   with the presigned `GET`, then cache by `image_ref`. Downsample to ≤ ~1 MP before any upload/AI call.
4. **Server is the entitlement authority.** RevenueCat drives the paywall UX, but a `402`/`429` from
   the API is honored regardless of local state.
5. **Today is computed on-device** from `cadence_days` + `last_done_at`; no server call to know
   what's due.
6. **The bud is delight, never hostage (§8 framing rule).** "Look what's growing for you," never
   "pay or it stays a seed." The plant/bud is never shamed or harmed.

## Workflow

- Build per **iOS-PRD §12** phases; keep commits small and one logical change each.
- Mirror the backend JSON field names exactly (snake_case in payloads; see `Models/`).
- When unsure about a money/entitlement path, follow the server's status code.
