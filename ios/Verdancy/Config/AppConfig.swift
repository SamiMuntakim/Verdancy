import Foundation

/// Build-time configuration. Replace the placeholders once the backend is deployed
/// (Phase 2/3) and Stage B (Sign in with Apple federation) is wired.
enum AppConfig {
    /// Base URL of the deployed HTTP API — the `HttpApiUrl` stack output.
    static let apiBaseURL = URL(string: "https://bygdoy8or3.execute-api.us-west-1.amazonaws.com")!

    /// Cognito user pool the app authenticates against (the deployed Phase-1 values).
    /// These are NOT secret — they ship in every client — and are used for native
    /// Sign in with Apple: the app posts the Apple token to `/auth/apple` and later
    /// refreshes tokens directly against Cognito with the client id below.
    static let cognitoRegion = "us-west-1"
    static let cognitoUserPoolId = "us-west-1_3nSrmRffE"
    static let cognitoAppClientId = "6jsmcp3h5g51brqas321f94u3"

    /// Google OAuth iOS client id (public). Sign-in exchanges the resulting Google
    /// ID token at `/auth/google`. The reversed-client-id is the OAuth redirect
    /// scheme Google requires for the native/ASWebAuthenticationSession flow.
    static let googleClientID =
        "463079233513-jr0tij8ftp393jnccot9brr7equs9skj.apps.googleusercontent.com"
    static let googleReversedClientID =
        "com.googleusercontent.apps.463079233513-jr0tij8ftp393jnccot9brr7equs9skj"

    /// RevenueCat public SDK key (App Store).
    static let revenueCatAPIKey = "appl_UotmnRxURcklrwrZorlKJcEoKAQ"

    /// RevenueCat entitlement identifier that grants the subscriber experience.
    static let entitlementID = "premium"

    /// When `true`, the app uses `MockAuthService` + sample data so the UI is fully
    /// runnable offline (previews/dev). `false` uses `NativeAppleAuthService` —
    /// native Sign in with Apple against the deployed Cognito pool above.
    static let useMockAuth = false

    /// Free identify allowance per day, mirrored from the backend
    /// `FREE_DAILY_AI_LIMIT` purely for client-side messaging ("2 free scans a day").
    /// The server is the real gate. Free is ID-only — no care plans, reminders,
    /// diagnose, buddies, or trees; those are the premium value (iOS-PRD §7/§8).
    static let freeDailyScanCount = 2

    /// Named planting partner (iOS-PRD §10: provably real trees, never vague).
    /// Trees are funded through Tree-Nation, which issues a certificate per tree.
    /// This must name the partner we actually plant with — see `docs/tree-nation-api.md`.
    static let plantingPartner = "Tree-Nation"

    /// Flip on once real App Store reviews exist — never show fabricated social
    /// proof. Gates the rating row on the paywall.
    static let showPaywallRating = false

    /// Remote AI-generated Plant Buddy sprites (backend Appendix A) are OFF for
    /// launch: every plant shows the bundled placeholder sprite, pending a
    /// professionally authored sprite sheet. Flip to `true` to re-enable the
    /// `POST /buddy` generation path and the CloudFront-served sprites.
    static let budBackendEnabled = false

    /// Public site (GitHub Pages from /docs; swap for verdancy.app when the domain
    /// is live). Legal pages are App Store requirements.
    static let siteBaseURL = "https://verdancy.app"
    static let privacyURL = URL(string: "\(siteBaseURL)/privacy.html")!
    static let termsURL = URL(string: "\(siteBaseURL)/terms.html")!
    static let supportURL = URL(string: "\(siteBaseURL)/support.html")!
    static let treeCounterURL = URL(string: "\(siteBaseURL)/trees.html")!
}
