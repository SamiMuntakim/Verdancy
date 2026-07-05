import Foundation

/// Bundled starter-bud sprites (iOS-PRD §9): a dormant bud, a generic fallback
/// bloom, and four silhouettes covering the most common first-scan houseplants.
/// Keyword-matched against the normalized species string; anything unmatched gets
/// the (still charming) generic bud.
enum BudSprites {
    static let dormant = "bud-dormant"
    static let generic = "bud-bloom-generic"

    private static let silhouettes: [(keywords: [String], asset: String)] = [
        (
            ["monstera", "philodendron", "ficus", "spathiphyllum", "peace lily", "zamioculcas",
             "zz", "rubber", "calathea", "alocasia", "anthurium"],
            "bud-bloom-broadleaf"
        ),
        (
            ["sansevieria", "trifasciata", "snake", "dracaena", "yucca"],
            "bud-bloom-snake"
        ),
        (
            ["pothos", "epipremnum", "ivy", "hedera", "chlorophytum", "spider", "tradescantia",
             "string of", "hoya", "philodendron hederaceum"],
            "bud-bloom-trailing"
        ),
        (
            ["aloe", "echeveria", "succulent", "haworthia", "crassula", "jade", "agave",
             "kalanchoe", "sedum", "cact"],
            "bud-bloom-succulent"
        ),
    ]

    /// Asset name for a bloomed bud, from the normalized species.
    static func bloomAsset(for species: String) -> String {
        let s = species.lowercased()
        for entry in silhouettes where entry.keywords.contains(where: { s.contains($0) }) {
            return entry.asset
        }
        return generic
    }
}
