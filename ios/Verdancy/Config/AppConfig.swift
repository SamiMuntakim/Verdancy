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

    /// RevenueCat public SDK key (App Store).
    static let revenueCatAPIKey = "appl_UotmnRxURcklrwrZorlKJcEoKAQ"

    /// RevenueCat entitlement identifier that grants the subscriber experience.
    static let entitlementID = "premium"

    /// When `true`, the app uses `MockAuthService` + sample data so the UI is fully
    /// runnable offline (previews/dev). `false` uses `NativeAppleAuthService` —
    /// native Sign in with Apple against the deployed Cognito pool above.
    static let useMockAuth = false

    /// Free identify allowance, mirrored from the backend `FREE_AI_LIFETIME_LIMIT`
    /// purely for client-side messaging ("your first scan is free"). The server is
    /// the real gate.
    static let freeScanMessageCount = 1

    /// Named planting partner (iOS-PRD §10: provably real trees, never vague).
    static let plantingPartner = "One Tree Planted"

    /// Flip on once real App Store reviews exist — never show fabricated social
    /// proof. Gates the rating row on the paywall.
    static let showPaywallRating = false

    /// Public site (GitHub Pages from /docs; swap for verdancy.app when the domain
    /// is live). Legal pages are App Store requirements.
    static let siteBaseURL = "https://samimuntakim.github.io/Verdancy"
    static let privacyURL = URL(string: "\(siteBaseURL)/privacy.html")!
    static let termsURL = URL(string: "\(siteBaseURL)/terms.html")!
    static let supportURL = URL(string: "\(siteBaseURL)/support.html")!
    static let treeCounterURL = URL(string: "\(siteBaseURL)/trees.html")!
}
