import Foundation
import Security

/// The Cognito session the app holds after a native sign-in. `expiresAt` is the
/// absolute expiry of the id/access tokens; the refresh token outlives them.
struct AuthTokens: Codable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// Keychain-backed storage for the Cognito session. Tokens are sensitive, so they
/// live in the Keychain (not UserDefaults) — device-only (no iCloud sync),
/// readable after first unlock so a background refresh can run.
enum TokenStore {
    private static let service = "com.verdancy.app.auth"
    private static let account = "cognito-session"

    static func load() -> AuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data)
        else { return nil }
        return tokens
    }

    static func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
