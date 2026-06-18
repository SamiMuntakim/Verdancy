import Foundation

/// In-memory auth for previews and offline development (no Cognito needed).
/// Active when `AppConfig.useMockAuth == true`.
final class MockAuthService: AuthService {
    private var signedIn: Bool

    init(startSignedIn: Bool = false) {
        self.signedIn = startSignedIn
    }

    func idToken(forceRefresh: Bool) async throws -> String {
        guard signedIn else { throw APIError.unauthorized }
        return "mock.jwt.token"
    }

    func isSignedIn() async -> Bool { signedIn }

    func userId() async -> String? { signedIn ? "mock-sub" : nil }

    func signInWithApple() async throws {
        try? await Task.sleep(for: .milliseconds(400))
        signedIn = true
    }

    func signOut() async { signedIn = false }
}
