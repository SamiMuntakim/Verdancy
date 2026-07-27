import Foundation

/// Native federated sign-in → real Cognito user-pool tokens, with **no Amplify and
/// no SDKs**. Apple uses the native `ASAuthorizationController` system sheet; Google
/// uses OAuth + PKCE in an `ASWebAuthenticationSession`. Either way the resulting
/// provider token is posted to the backend (`/auth/apple` or `/auth/google`), which
/// mints a Cognito session we store in the Keychain. `idToken` serves the cached
/// token and refreshes it against Cognito near expiry (coalescing concurrent
/// refreshes).
///
/// Main-actor isolated so the token/refresh state can't race; the network awaits
/// inside still run off the main thread.
@MainActor
final class NativeAuthService: AuthService {
    private var tokens: AuthTokens?
    private var appleController: AppleSignInController?
    private var googleController: GoogleSignInController?
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
        appleController = controller
        defer { appleController = nil }

        let credential = try await controller.signIn()
        try await exchangeAndStore(
            path: "auth/apple",
            identityToken: credential.identityToken,
            nonce: credential.rawNonce)
    }

    func signInWithGoogle() async throws {
        let controller = GoogleSignInController()
        googleController = controller
        defer { googleController = nil }

        let credential = try await controller.signIn()
        try await exchangeAndStore(
            path: "auth/google",
            identityToken: credential.identityToken,
            nonce: credential.rawNonce)
    }

    func signInWithEmail(_ email: String, password: String) async throws {
        let session = try await EmailAuth.signIn(email: email, password: password)
        tokens = session
        TokenStore.save(session)
    }

    func signOut() async {
        tokens = nil
        refreshTask = nil
        TokenStore.clear()
    }

    private func exchangeAndStore(path: String, identityToken: String, nonce: String) async throws {
        let session = try await CognitoAuthAPI.exchange(
            path: path, identityToken: identityToken, nonce: nonce)
        tokens = session
        TokenStore.save(session)
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
