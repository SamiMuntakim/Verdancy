import Foundation
import Observation

/// A saved diagnosis attached to a plant — the triage card turned into an ongoing
/// health record ("Treated for root rot, June 30").
struct DiagnosisRecord: Codable, Identifiable {
    let id: String
    let plantId: String
    let issue: String
    let likelyCause: String
    let severity: String
    let steps: [String]
    let at: String

    var severityLevel: Severity? { Severity(rawValue: severity) }
}

/// On-device diagnosis history (local-only: the backend has no health-log endpoint,
/// and adding one needs explicit approval — this store is the seam if it lands).
@MainActor
@Observable
final class HealthLog {
    static let shared = HealthLog()

    private(set) var records: [DiagnosisRecord] = []

    private static var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("health-log.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let decoded = try? JSONDecoder().decode([DiagnosisRecord].self, from: data) {
            records = decoded
        }
    }

    func records(for plantId: String) -> [DiagnosisRecord] {
        records.filter { $0.plantId == plantId }.sorted { $0.at > $1.at }
    }

    func add(_ card: DiagnosisCard, plantId: String) {
        records.append(DiagnosisRecord(
            id: UUID().uuidString, plantId: plantId, issue: card.issue,
            likelyCause: card.likelyCause, severity: card.severity, steps: card.steps,
            at: ISO.string()))
        save()
        Analytics.log("diagnosis_saved", ["severity": card.severity])
    }

    /// Cascade when a plant is deleted.
    func removeAll(plantId: String) {
        records.removeAll { $0.plantId == plantId }
        save()
    }

    /// Full wipe on sign-out / account deletion.
    func clear() {
        records = []
        try? FileManager.default.removeItem(at: Self.url)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
