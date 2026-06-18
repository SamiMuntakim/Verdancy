import Foundation

private func daysAgo(_ n: Int) -> String {
    ISO.string(Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date())
}

extension Plant {
    static let sample = Plant(
        plantId: "p1", commonName: "Monstera", species: "monstera deliciosa", nickname: "Monty",
        imageRef: "u/mock/p/p1/a.jpg", toxicity: "High", lightingNeeds: "Bright, indirect light",
        fertilizerInfo: "Monthly in spring and summer", confidence: "High",
        care: CareMap(
            water: CareTask(cadenceDays: 7, lastDoneAt: daysAgo(9)),
            fertilize: CareTask(cadenceDays: 30, lastDoneAt: daysAgo(10)),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
        createdAt: daysAgo(40), downloadUrl: nil,
        buddy: Buddy(status: "ready", spriteUrl: nil, styleVersion: 1))

    static let sampleSnake = Plant(
        plantId: "p2", commonName: "Snake Plant", species: "dracaena trifasciata", nickname: nil,
        imageRef: "u/mock/p/p2/a.jpg", toxicity: "Low", lightingNeeds: "Low to bright light",
        fertilizerInfo: "Sparingly", confidence: "High",
        care: CareMap(
            water: CareTask(cadenceDays: 14, lastDoneAt: daysAgo(3)),
            fertilize: CareTask(cadenceDays: 60, lastDoneAt: nil),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
        createdAt: daysAgo(20), downloadUrl: nil,
        buddy: Buddy(status: "pending", spriteUrl: nil, styleVersion: 1))

    static let sampleUnknown = Plant(
        plantId: "p3", commonName: "Unknown Plant", species: "unknown", nickname: "Mystery",
        imageRef: "u/mock/p/p3/a.jpg", toxicity: "High", lightingNeeds: "Unknown",
        fertilizerInfo: "Unknown", confidence: "Low",
        care: CareMap(
            water: CareTask(cadenceDays: nil, lastDoneAt: nil),
            fertilize: CareTask(cadenceDays: nil, lastDoneAt: nil),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
        createdAt: daysAgo(2), downloadUrl: nil, buddy: nil)

    static let samples: [Plant] = [sample, sampleSnake, sampleUnknown]

    /// Build a local Plant from an identify result (used by mock-mode save).
    static func mock(from card: CareCard, nickname: String?) -> Plant {
        Plant(
            plantId: UUID().uuidString, commonName: card.commonName, species: card.species,
            nickname: nickname, imageRef: "u/mock/p/\(UUID().uuidString)/a.jpg",
            toxicity: card.toxicity, lightingNeeds: card.lightingNeeds,
            fertilizerInfo: card.fertilizerInfo, confidence: card.confidence,
            care: CareMap(
                water: CareTask(cadenceDays: card.isUnidentified ? nil : card.waterCadenceDays, lastDoneAt: nil),
                fertilize: CareTask(cadenceDays: card.isUnidentified ? nil : card.fertilizeCadenceDays, lastDoneAt: nil),
                prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
            createdAt: ISO.string(), downloadUrl: nil, buddy: nil)
    }
}

extension TreeStatus {
    static let sample = TreeStatus(treesPledged: 3, milestones: ["first_plant", "fifth_plant"])
}

extension CareCard {
    static let sample = CareCard(
        species: "monstera deliciosa", commonName: "Monstera Deliciosa", toxicity: "High",
        waterCadenceDays: 7, fertilizeCadenceDays: 30, lightingNeeds: "Bright, indirect light",
        fertilizerInfo: "Monthly in spring and summer", confidence: "High")

    static let sampleUnknown = CareCard(
        species: "unknown", commonName: "Unknown Plant", toxicity: "High",
        waterCadenceDays: nil, fertilizeCadenceDays: nil, lightingNeeds: "Unknown",
        fertilizerInfo: "Unknown", confidence: "Low")
}

extension DiagnosisCard {
    static let sample = DiagnosisCard(
        issue: "Overwatering / early root rot", likelyCause: "Soil staying wet too long",
        severity: "Moderate",
        steps: ["Let the soil dry out fully before the next water",
                "Check roots for soft brown sections and trim them",
                "Move to brighter, indirect light to speed drying"],
        confidence: "Medium")
}
