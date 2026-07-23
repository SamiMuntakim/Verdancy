import Foundation

/// Minimal JWT reader — we only ever need the `sub` claim off our own Cognito id
/// token (identity for RevenueCat + local state). The token's signature is trusted
/// because it came straight from Cognito over TLS; we never authorize off it here.
enum JWT {
    static func subject(of idToken: String) -> String? {
        claims(of: idToken)?["sub"] as? String
    }

    static func claims(of idToken: String) -> [String: Any]? {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 =
            String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
