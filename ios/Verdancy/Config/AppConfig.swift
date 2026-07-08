import Foundation

/// Build-time configuration. Replace the placeholders once the backend is deployed
/// (Phase 2/3) and Stage B (Sign in with Apple federation) is wired.
enum AppConfig {
    /// Base URL of the deployed HTTP API — the `HttpApiUrl` stack output.
    static let apiBaseURL = URL(string: "https://REPLACE-ME.execute-api.us-west-1.amazonaws.com")!

    /// RevenueCat public SDK key (App Store).
    static let revenueCatAPIKey = "REPLACE-ME"

    /// RevenueCat entitlement identifier that grants the subscriber experience.
    static let entitlementID = "premium"

    /// While `true` (the default until Cognito/Amplify is configured), the app uses
    /// `MockAuthService` + sample data so the UI is fully runnable offline. Flip to
    /// `false` once `amplifyconfiguration.json` is filled in.
    static let useMockAuth = true

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
