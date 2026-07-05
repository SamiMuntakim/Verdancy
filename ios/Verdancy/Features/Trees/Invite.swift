import Foundation

/// Referral content (iOS-PRD §10): "invite a friend, plant a tree for both."
/// The friend enters the invite code in Settings; when their first purchase lands,
/// the backend plants a tree for both sides.
enum Invite {
    static let url = URL(string: "\(AppConfig.siteBaseURL)/")!

    static func message(code: String?) -> String {
        var text =
            "I'm keeping my plants alive (and growing a real forest 🌳) with Verdancy — "
            + "join me and we each get a tree planted."
        if let code, !code.isEmpty {
            text += " Use my invite code: \(code)"
        }
        return text
    }
}
