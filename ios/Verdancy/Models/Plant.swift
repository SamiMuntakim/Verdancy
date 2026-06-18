import Foundation

/// A saved plant, as returned by `GET /plants` (decoded with
/// `.convertFromSnakeCase`, so `common_name` → `commonName`, etc.).
struct Plant: Codable, Identifiable, Hashable {
    let plantId: String
    let commonName: String
    let species: String
    let nickname: String?
    let imageRef: String?
    let toxicity: String?
    let lightingNeeds: String?
    let fertilizerInfo: String?
    let confidence: String?
    let care: CareMap
    let createdAt: String?
    let downloadUrl: String?
    let buddy: Buddy?

    var id: String { plantId }
    var displayName: String { nickname?.isEmpty == false ? nickname! : commonName }
    var toxicityLevel: Toxicity? { toxicity.flatMap(Toxicity.init(rawValue:)) }

    /// Copy with a new care map (for optimistic local updates).
    func withCare(_ care: CareMap) -> Plant {
        Plant(plantId: plantId, commonName: commonName, species: species, nickname: nickname,
              imageRef: imageRef, toxicity: toxicity, lightingNeeds: lightingNeeds,
              fertilizerInfo: fertilizerInfo, confidence: confidence, care: care,
              createdAt: createdAt, downloadUrl: downloadUrl, buddy: buddy)
    }
}

struct CareMap: Codable, Hashable {
    let water: CareTask
    let fertilize: CareTask
    let prune: CareTask

    func task(for type: CareType) -> CareTask {
        switch type {
        case .water: return water
        case .fertilize: return fertilize
        case .prune: return prune
        }
    }
}

struct CareTask: Codable, Hashable {
    let cadenceDays: Int?
    let lastDoneAt: String?

    /// `nil` when there's no cadence (unidentified plant → no schedule, iOS-PRD §6).
    func nextDue(now: Date = Date()) -> Date? {
        guard let cadenceDays else { return nil }
        let last = ISO.date(lastDoneAt) ?? now
        return Calendar.current.date(byAdding: .day, value: cadenceDays, to: last)
    }
}

enum CareType: String, CaseIterable, Codable {
    case water, fertilize, prune

    var title: String {
        switch self {
        case .water: return "Water"
        case .fertilize: return "Fertilize"
        case .prune: return "Prune"
        }
    }

    var systemImage: String {
        switch self {
        case .water: return "drop.fill"
        case .fertilize: return "leaf.fill"
        case .prune: return "scissors"
        }
    }
}

/// The shared per-species buddy (post-MVP backend; resolved into `GET /plants`).
struct Buddy: Codable, Hashable {
    let status: String
    let spriteUrl: String?
    let styleVersion: Int?

    var isReady: Bool { status == "ready" && spriteUrl != nil }
}

enum Toxicity: String, Codable {
    case high = "High", medium = "Medium", low = "Low", none = "None"

    /// Pet/child safety note worth surfacing (iOS-PRD §6).
    var isConcerning: Bool { self == .high || self == .medium }
}
