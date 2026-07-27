import Foundation

/// `POST /identify` result — identity only (name + taxonomy + pet toxicity). The
/// care schedule is produced later, tailored to the plant's environment, by the
/// personalized care plan (`POST /plants/{id}/care-plan`).
struct CareCard: Codable, Hashable {
    let species: String
    let commonName: String
    let toxicity: String
    let taxonomy: Taxonomy?
    let confidence: String

    /// Honor server caution (iOS-PRD §6): low confidence or "Unknown Plant".
    var isUnidentified: Bool {
        confidence == Confidence.low.rawValue || commonName == "Unknown Plant"
    }

    var toxicityLevel: Toxicity? { Toxicity(rawValue: toxicity) }
}

/// Botanical classification shown on the scan result + plant detail.
struct Taxonomy: Codable, Hashable {
    let family: String
    let genus: String
    let species: String
    let cultivar: String?

    /// e.g. "Araceae · Monstera" — the classification line under the name.
    var lineage: String { "\(family) · \(genus)" }

    /// e.g. "Monstera deliciosa 'Albo'" — the scientific name with any cultivar.
    var scientificName: String {
        let base = "\(genus) \(species)"
        guard let cultivar, !cultivar.isEmpty else { return base }
        return "\(base) '\(cultivar)'"
    }
}

/// `POST /plants/{id}/care-plan` result — the environment-tailored care plan.
/// Decoded with `.convertFromSnakeCase` (cadence_days → cadenceDays, etc.).
struct CarePlan: Codable, Hashable {
    let water: WaterPlan
    let light: LightPlan
    let nutrients: NutrientsPlan
}

struct WaterPlan: Codable, Hashable {
    let amount: String
    let cadenceDays: Int
    let instruction: String
}

struct LightPlan: Codable, Hashable {
    let summary: String
    let instruction: String
}

struct NutrientsPlan: Codable, Hashable {
    let fertilizeCadenceDays: Int?
    let instruction: String
}

/// `POST /diagnose` result — the triage card.
struct DiagnosisCard: Codable, Hashable {
    let issue: String
    let likelyCause: String
    let severity: String
    let steps: [String]
    let confidence: String

    var severityLevel: Severity? { Severity(rawValue: severity) }
}

enum Confidence: String, Codable {
    case high = "High", medium = "Medium", low = "Low"
}

enum Severity: String, Codable {
    case critical = "Critical", moderate = "Moderate", minor = "Minor", healthy = "Healthy"
}
