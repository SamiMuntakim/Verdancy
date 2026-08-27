import Foundation

/// A failure from an email/password Cognito call, in a form the UI can act on.
enum EmailAuthError: Error, Equatable {
    /// The account exists but the email isn't verified yet — route to code entry.
    case needsConfirmation
    /// A user-facing message to show as-is.
    case message(String)
}

/// Email/password auth straight against Cognito's IDP endpoint (plain `URLSession`,
/// no SDK — same approach as token refresh). Sign-up / confirm / reset don't return
/// a session; after them the caller signs in via `NativeAuthService` to get tokens.
/// Verification + reset emails are sent by Cognito's built-in email (no SES).
enum EmailAuth {
    private static var endpoint: URL {
        URL(string: "https://cognito-idp.\(AppConfig.cognitoRegion).amazonaws.com/")!
    }
    private static var clientId: String { AppConfig.cognitoAppClientId }

    /// Sign in and return a Cognito session (used by `NativeAuthService`).
    static func signIn(email: String, password: String) async throws -> AuthTokens {
        let data = try await call(
            "InitiateAuth",
            [
                "AuthFlow": "USER_PASSWORD_AUTH",
                "ClientId": clientId,
                "AuthParameters": ["USERNAME": email, "PASSWORD": password],
            ])
        struct Body: Decodable {
            struct Result: Decodable {
                let AccessToken: String
                let IdToken: String
                let RefreshToken: String
                let ExpiresIn: Int
            }
            let AuthenticationResult: Result
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            throw EmailAuthError.message("We got an unexpected response. Please try again.")
        }
        let r = body.AuthenticationResult
        return AuthTokens(
            idToken: r.IdToken, accessToken: r.AccessToken, refreshToken: r.RefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(r.ExpiresIn)))
    }

    static func signUp(email: String, password: String) async throws {
        _ = try await call("SignUp", ["ClientId": clientId, "Username": email, "Password": password])
    }

    static func confirmSignUp(email: String, code: String) async throws {
        _ = try await call(
            "ConfirmSignUp", ["ClientId": clientId, "Username": email, "ConfirmationCode": code])
    }

    static func resendCode(email: String) async throws {
        _ = try await call("ResendConfirmationCode", ["ClientId": clientId, "Username": email])
    }

    static func forgotPassword(email: String) async throws {
        _ = try await call("ForgotPassword", ["ClientId": clientId, "Username": email])
    }

    static func confirmForgotPassword(email: String, code: String, newPassword: String) async throws
    {
        _ = try await call(
            "ConfirmForgotPassword",
            [
                "ClientId": clientId, "Username": email, "ConfirmationCode": code,
                "Password": newPassword,
            ])
    }

    private static func call(_ action: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "AWSCognitoIdentityProviderService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmailAuthError.message("No response from the server.")
        }
        if (200..<300).contains(http.statusCode) { return data }
        throw mapError(data)
    }

    /// Map Cognito's `__type` error to something the user (or the flow) understands.
    private static func mapError(_ data: Data) -> EmailAuthError {
        let type =
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["__type"]
            as? String ?? ""
        let name = type.components(separatedBy: "#").last ?? type
        switch name {
        case "UserNotConfirmedException": return .needsConfirmation
        case "NotAuthorizedException": return .message("Incorrect email or password.")
        case "UsernameExistsException": return .message("An account with that email already exists.")
        case "CodeMismatchException": return .message("That code isn't right.")
        case "ExpiredCodeException": return .message("That code expired. Request a new one.")
        case "UserNotFoundException": return .message("No account found for that email.")
        case "InvalidPasswordException", "InvalidParameterException":
            return .message("Use 12+ characters with an uppercase, lowercase, number, and symbol.")
        case "LimitExceededException", "TooManyRequestsException":
            return .message("Too many attempts. Please wait a bit and try again.")
        default: return .message("Something went wrong. Please try again.")
        }
    }
}
