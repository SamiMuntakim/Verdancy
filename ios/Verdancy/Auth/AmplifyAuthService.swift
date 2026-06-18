import Foundation
import Amplify
import AWSCognitoAuthPlugin
import AuthenticationServices

/// Cognito-backed auth via Amplify Swift (Auth only). Sign in with Apple is
/// federated through the Cognito hosted domain (`signInWithWebUI(for: .apple)`),
/// presented in an `ASWebAuthenticationSession` so it stays in-app.
///
/// NOTE: requires `amplifyconfiguration.json` (see the template) and Stage B
/// (Apple federation) deployed. Authored on Windows — verify on a Mac.
final class AmplifyAuthService: AuthService {
    /// Call once at launch before any auth use.
    static func configure() {
        do {
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.configure()
        } catch {
            assertionFailure("Amplify configuration failed: \(error)")
        }
    }

    func idToken(forceRefresh: Bool) async throws -> String {
        let session: AuthSession
        if forceRefresh {
            session = try await Amplify.Auth.fetchAuthSession(
                options: .init(forceRefresh: true))
        } else {
            session = try await Amplify.Auth.fetchAuthSession()
        }
        guard let provider = session as? AuthCognitoTokensProvider else {
            throw APIError.unauthorized
        }
        switch provider.getCognitoTokens() {
        case .success(let tokens): return tokens.idToken
        case .failure: throw APIError.unauthorized
        }
    }

    func isSignedIn() async -> Bool {
        (try? await Amplify.Auth.fetchAuthSession().isSignedIn) ?? false
    }

    func userId() async -> String? {
        guard let user = try? await Amplify.Auth.getCurrentUser() else { return nil }
        return user.userId
    }

    @MainActor
    func signInWithApple() async throws {
        let result = try await Amplify.Auth.signInWithWebUI(
            for: .apple,
            presentationAnchor: Self.presentationAnchor()
        )
        guard result.isSignedIn else { throw APIError.unauthorized }
    }

    func signOut() async {
        _ = await Amplify.Auth.signOut()
    }

    @MainActor
    private static func presentationAnchor() -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
