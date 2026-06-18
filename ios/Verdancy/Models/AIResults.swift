import Foundation

/// `POST /identify` result — the care card.
struct CareCard: Codable, Hashable {
    let species: String
    let commonName: String
    let toxicity: String
    let waterCadenceDays: Int?
    let fertilizeCadenceDays: Int?
    let lightingNeeds: String
    let fertilizerInfo: String
    let confidence: String

    /// Honor server caution (iOS-PRD §6): low confidence or "Unknown Plant" →
    /// never auto-apply a schedule.
    var isUnidentified: Bool {
        confidence == Confidence.low.rawValue
            || commonName == "Unknown Plant"
            || waterCadenceDays == nil
    }

    var toxicityLevel: Toxicity? { Toxicity(rawValue: toxicity) }
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
