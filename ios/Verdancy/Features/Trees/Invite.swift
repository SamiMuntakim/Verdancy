import Foundation

/// Referral content (iOS-PRD §10): "invite a friend, plant a tree for both."
/// The invite link + per-user attribution need a backend referral endpoint (§13);
/// this is the shareable surface.
enum Invite {
    static let url = URL(string: "https://verdancy.app/invite")!
    static let message =
        "I'm keeping my plants alive (and growing a real forest 🌳) with Verdancy — "
        + "join me and we each get a tree planted."
}
