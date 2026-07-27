import AuthenticationServices
import CryptoKit
import UIKit

/// Drives one Google sign-in via OAuth 2.0 + PKCE in an `ASWebAuthenticationSession`
/// (no GoogleSignIn SDK — keeps the app dependency-free). Google has no native
/// system sheet like Apple's, so this is a browser-based consent by design.
///
/// Nonce handling matches the Apple path: the SHA-256 of a raw nonce is sent as the
/// OpenID `nonce` (Google echoes it into the ID token), and the raw value goes to
/// the backend to verify — the replay protection `/auth/google` checks.
final class GoogleSignInController: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Credential {
        let identityToken: String
        let rawNonce: String
    }

    private var session: ASWebAuthenticationSession?

    @MainActor
    func signIn() async throws -> Credential {
        let rawNonce = Self.randomString()
        let state = Self.randomString()
        let codeVerifier = Self.randomString(length: 64)
        let redirectURI = "\(AppConfig.googleReversedClientID):/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: AppConfig.googleClientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: Self.sha256Base64Url(codeVerifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "nonce", value: Self.sha256Hex(rawNonce)),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: AppConfig.googleReversedClientID
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? APIError.unauthorized)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }

        // Guard against CSRF (state) and extract the authorization code.
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
            let code = items.first(where: { $0.name == "code" })?.value
        else {
            throw APIError.unauthorized
        }

        let idToken = try await exchangeCode(
            code, codeVerifier: codeVerifier, redirectURI: redirectURI)
        return Credential(identityToken: idToken, rawNonce: rawNonce)
    }

    /// Exchange the authorization code for tokens (public client + PKCE, no secret).
    private func exchangeCode(
        _ code: String, codeVerifier: String, redirectURI: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "code": code,
            "client_id": AppConfig.googleClientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        request.httpBody = form
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.unauthorized
        }
        struct TokenResponse: Decodable { let id_token: String }
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw APIError.decoding
        }
        return body.id_token
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene =
            UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }

    // MARK: - Crypto helpers

    /// URL-safe random string usable as a nonce, state, or PKCE code verifier.
    private static func randomString(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            return UUID().uuidString + UUID().uuidString
        }
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Base64Url(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
