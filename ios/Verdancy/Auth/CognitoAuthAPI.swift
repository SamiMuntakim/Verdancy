import Foundation

/// The two unauthenticated auth network calls, done with plain `URLSession` (no
/// SDK — this is what lets us drop Amplify): exchanging a native Apple identity
/// token for Cognito tokens via our backend, and refreshing tokens directly
/// against Cognito's IDP endpoint.
enum CognitoAuthAPI {
    /// Exchange a native provider identity token for Cognito user-pool tokens via
    /// `POST {apiBaseURL}/{path}` (e.g. `auth/apple`, `auth/google`). The backend
    /// verifies the token, find-or-creates the user, and mints the tokens.
    static func exchange(path: String, identityToken: String, nonce: String) async throws
        -> AuthTokens
    {
        let url = AppConfig.apiBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identity_token": identityToken,
            "nonce": nonce,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response, data: data)

        struct Body: Decodable {
            let id_token: String
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }
        let body = try decode(Body.self, from: data)
        return AuthTokens(
            idToken: body.id_token,
            accessToken: body.access_token,
            refreshToken: body.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(body.expires_in)))
    }

    /// Refresh id/access tokens via Cognito `InitiateAuth` (REFRESH_TOKEN_AUTH).
    /// Cognito does not return a new refresh token, so we carry the existing one.
    static func refresh(refreshToken: String) async throws -> AuthTokens {
        let url = URL(string: "https://cognito-idp.\(AppConfig.cognitoRegion).amazonaws.com/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "AWSCognitoIdentityProviderService.InitiateAuth",
            forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": AppConfig.cognitoAppClientId,
            "AuthParameters": ["REFRESH_TOKEN": refreshToken],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response, data: data)

        struct Body: Decodable {
            struct Result: Decodable {
                let AccessToken: String
                let IdToken: String
                let ExpiresIn: Int
            }
            let AuthenticationResult: Result
        }
        let result = try decode(Body.self, from: data).AuthenticationResult
        return AuthTokens(
            idToken: result.IdToken,
            accessToken: result.AccessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(result.ExpiresIn)))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    /// Cognito reports a dead session as **HTTP 400 + `NotAuthorizedException`**, not
    /// a 401 — so the status alone can't tell "your refresh token expired" apart from
    /// a transient outage. Read the error type out of the body: only that case means
    /// the session is unrecoverable and the user must sign in again; everything else
    /// stays a retryable failure that must NOT sign anyone out.
    private static func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("No response from the server.")
        }
        if (200..<300).contains(http.statusCode) { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        if let type = errorType(data), type.contains("NotAuthorized") || type.contains("UserNotFound") {
            throw APIError.unauthorized
        }
        throw APIError.server(http.statusCode)
    }

    /// The `__type` field of a Cognito error body (e.g. `NotAuthorizedException`).
    private static func errorType(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["__type"] as? String
    }
}
