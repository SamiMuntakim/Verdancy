import Foundation

/// Native Sign in with Apple → real Cognito user-pool tokens, with **no Amplify and
/// no web redirect**. `signInWithApple()` presents the system sheet, posts the
/// resulting identity token to `POST /auth/apple`, and stores the returned Cognito
/// session in the Keychain. `idToken` serves the cached token and refreshes it
/// against Cognito when it's near expiry (coalescing concurrent refreshes).
///
/// Main-actor isolated so the token/refresh state can't race; the network awaits
/// inside still run off the main thread.
@MainActor
final class NativeAppleAuthService: AuthService {
    private var tokens: AuthTokens?
    private var signInController: AppleSignInController?
    private var refreshTask: Task<AuthTokens, Error>?

    /// Refresh this many seconds before actual expiry to avoid racing the clock.
    private let expiryLeeway: TimeInterval = 60

    init() {
        tokens = TokenStore.load()
    }

    func idToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let tokens, tokens.expiresAt.timeIntervalSinceNow > expiryLeeway {
            return tokens.idToken
        }
        return try await refreshTokens().idToken
    }

    func isSignedIn() async -> Bool {
        tokens != nil
    }

    func userId() async -> String? {
        guard let idToken = tokens?.idToken else { return nil }
        return JWT.subject(of: idToken)
    }

    func signInWithApple() async throws {
        let controller = AppleSignInController()
        signInController = controller
        defer { signInController = nil }

        let credential = try await controller.signIn()
        let session = try await CognitoAuthAPI.exchangeApple(
            identityToken: credential.identityToken,
            nonce: credential.rawNonce)
        tokens = session
        TokenStore.save(session)
    }

    func signOut() async {
        tokens = nil
        refreshTask = nil
        TokenStore.clear()
    }

    /// Refresh the session, coalescing concurrent callers onto one network call.
    private func refreshTokens() async throws -> AuthTokens {
        if let refreshTask { return try await refreshTask.value }

        guard let refreshToken = tokens?.refreshToken else { throw APIError.unauthorized }
        let task = Task { try await CognitoAuthAPI.refresh(refreshToken: refreshToken) }
        refreshTask = task
        do {
            let refreshed = try await task.value
            tokens = refreshed
            TokenStore.save(refreshed)
            refreshTask = nil
            return refreshed
        } catch {
            refreshTask = nil
            throw error
        }
    }
}
