import AuthenticationServices
import CryptoKit
import UIKit

/// Drives one native Sign in with Apple request through `ASAuthorizationController`
/// (the system sheet — no web), bridging its delegate callbacks to `async/await`.
///
/// A fresh nonce is generated per sign-in: the SHA-256 of it is sent to Apple (and
/// echoed back inside the identity token), while the raw value is handed to the
/// backend to verify — that's the replay protection the `/auth/apple` Lambda checks.
final class AppleSignInController: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    struct Credential {
        let identityToken: String
        let rawNonce: String
    }

    private var continuation: CheckedContinuation<Credential, Error>?
    private var rawNonce = ""

    @MainActor
    func signIn() async throws -> Credential {
        let nonce = Self.randomNonce()
        rawNonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            continuation?.resume(throwing: APIError.unauthorized)
            continuation = nil
            return
        }
        continuation?.resume(returning: Credential(identityToken: identityToken, rawNonce: rawNonce))
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene =
            UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            // Extremely unlikely; fall back to UUID entropy rather than trap.
            return UUID().uuidString + UUID().uuidString
        }
        // URL-safe characters keep the nonce clean end-to-end.
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
