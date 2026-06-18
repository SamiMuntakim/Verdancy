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
}
