import Foundation

/// Authentication boundary (iOS-PRD §2): native Sign in with Apple federated into
/// Cognito. Behind a protocol so the implementation is swappable —
/// `NativeAppleAuthService` in the app, `MockAuthService` for previews/dev.
protocol AuthService: AnyObject {
    /// A valid Cognito JWT (id token). Implementations refresh as needed; pass
    /// `forceRefresh` to bypass the cache after a 401.
    func idToken(forceRefresh: Bool) async throws -> String
    func isSignedIn() async -> Bool
    /// The Cognito `sub` of the signed-in user, if any.
    func userId() async -> String?
    func signInWithApple() async throws
    func signInWithGoogle() async throws
    func signOut() async
}
