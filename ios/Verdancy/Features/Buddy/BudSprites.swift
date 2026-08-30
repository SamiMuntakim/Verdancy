import Foundation

/// Bundled Plant Bud sprites (iOS-PRD §9). The bloom sprite is chosen by the
/// **archetype** the backend `identify` step returns (six care/silhouette buckets),
/// which is authoritative. For legacy plants saved before archetypes existed
/// (`archetype == nil`) we fall back to keyword-matching the species string, then
/// to a leafy generic. The dormant teaser is a seed sprouting in a pot that blooms
/// into the archetype bud once the owner subscribes.
enum BudSprites {
    /// Pre-bloom teaser (non-subscriber / dormant): a seed in a pot — "something's
    /// forming." Blooms into the archetype bud on subscribe (framing rule §8).
    static let dormant = "bud-pot"
    /// Ultimate fallback bud when there's neither an archetype nor a keyword match.
    static let generic = "bud-broadleaf"

    /// Sprite for one of the six identify archetype buckets, or nil if unknown/absent.
    static func asset(forArchetype archetype: String?) -> String? {
        switch archetype {
        case "broadleaf": return "bud-broadleaf"
        case "trailing": return "bud-trailing"
        case "succulent": return "bud-succulent"
        case "upright": return "bud-upright"
        case "fern": return "bud-fern"
        case "orchid": return "bud-orchid"
        default: return nil
        }
    }

    /// Keyword fallback (legacy plants without an archetype) — maps species text to
    /// the same six buckets so old and new saves share the one art set.
    private static let silhouettes: [(keywords: [String], asset: String)] = [
        (
            ["monstera", "philodendron", "ficus", "spathiphyllum", "peace lily", "zamioculcas",
             "zz", "rubber", "calathea", "alocasia", "anthurium"],
            "bud-broadleaf"
        ),
        (
            ["sansevieria", "trifasciata", "snake", "dracaena", "yucca"],
            "bud-upright"
        ),
        (
            ["pothos", "epipremnum", "ivy", "hedera", "chlorophytum", "spider", "tradescantia",
             "string of", "hoya"],
            "bud-trailing"
        ),
        (
            ["aloe", "echeveria", "succulent", "haworthia", "crassula", "jade", "agave",
             "kalanchoe", "sedum", "cact"],
            "bud-succulent"
        ),
        (
            ["fern", "nephrolepis", "adiantum", "maidenhair", "asparagus fern", "pteris"],
            "bud-fern"
        ),
        (
            ["orchid", "phalaenopsis", "bromeliad", "tillandsia", "guzmania", "epiphyt"],
            "bud-orchid"
        ),
    ]

    /// Bloomed-bud sprite for a plant: prefer the identify archetype, then a
    /// species keyword match, then the leafy generic.
    static func bloomAsset(forArchetype archetype: String?, species: String) -> String {
        if let asset = asset(forArchetype: archetype) { return asset }
        let s = species.lowercased()
        for entry in silhouettes where entry.keywords.contains(where: { s.contains($0) }) {
            return entry.asset
        }
        return generic
    }

    /// Keyword-only entry point for call sites that don't carry an archetype.
    static func bloomAsset(for species: String) -> String {
        bloomAsset(forArchetype: nil, species: species)
    }
}
