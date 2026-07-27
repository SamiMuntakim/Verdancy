import Foundation

private func daysAgo(_ n: Int) -> String {
    ISO.string(Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date())
}

extension Plant {
    static let sampleTaxonomy = Taxonomy(
        family: "Araceae", genus: "Monstera", species: "deliciosa", cultivar: "Albo")

    static let sample = Plant(
        plantId: "p1", commonName: "Monstera", species: "monstera deliciosa", nickname: "Monty",
        imageRef: "u/mock/p/p1/a.jpg", toxicity: "High", taxonomy: sampleTaxonomy,
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High",
        care: CareMap(
            water: CareTask(cadenceDays: 10, lastDoneAt: daysAgo(9)),
            fertilize: CareTask(cadenceDays: 30, lastDoneAt: daysAgo(10)),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
        carePlan: .sample, createdAt: daysAgo(40), downloadUrl: nil,
        buddy: Buddy(status: "ready", spriteUrl: nil, styleVersion: 1))

    static let sampleSnake = Plant(
        plantId: "p2", commonName: "Snake Plant", species: "dracaena trifasciata", nickname: nil,
        imageRef: "u/mock/p/p2/a.jpg", toxicity: "Low",
        taxonomy: Taxonomy(family: "Asparagaceae", genus: "Dracaena", species: "trifasciata", cultivar: nil),
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High",
        care: CareMap(
            water: CareTask(cadenceDays: nil, lastDoneAt: nil),
            fertilize: CareTask(cadenceDays: nil, lastDoneAt: nil),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
        carePlan: nil, createdAt: daysAgo(20), downloadUrl: nil,
        buddy: Buddy(status: "pending", spriteUrl: nil, styleVersion: 1))

    static let sampleUnknown = Plant(
        plantId: "p3", commonName: "Unknown Plant", species: "unknown", nickname: "Mystery",
        imageRef: "u/mock/p/p3/a.jpg", toxicity: "High", taxonomy: nil,
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "Low",
        care: CareMap(
            water: CareTask(cadenceDays: nil, lastDoneAt: nil),
            fertilize: CareTask(cadenceDays: nil, lastDoneAt: nil),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
        carePlan: nil, createdAt: daysAgo(2), downloadUrl: nil, buddy: nil)

    static let samples: [Plant] = [sample, sampleSnake, sampleUnknown]

    /// Build a local Plant from an identify result (used by mock-mode save). Care
    /// starts empty — the personalized plan fills it in (mock-mode synthesizes one).
    static func mock(from card: CareCard, nickname: String?) -> Plant {
        Plant(
            plantId: UUID().uuidString, commonName: card.commonName, species: card.species,
            nickname: nickname, imageRef: "u/mock/p/\(UUID().uuidString)/a.jpg",
            toxicity: card.toxicity, taxonomy: card.taxonomy, lightingNeeds: nil,
            fertilizerInfo: nil, confidence: card.confidence,
            care: CareMap(
                water: CareTask(cadenceDays: nil, lastDoneAt: nil),
                fertilize: CareTask(cadenceDays: nil, lastDoneAt: nil),
                prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
            carePlan: nil, createdAt: ISO.string(), downloadUrl: nil, buddy: nil)
    }

    /// Copy with a generated care plan applied (mock-mode + optimistic updates).
    func withCarePlan(_ plan: CarePlan) -> Plant {
        let newCare = CareMap(
            water: CareTask(cadenceDays: plan.water.cadenceDays, lastDoneAt: care.water.lastDoneAt),
            fertilize: CareTask(cadenceDays: plan.nutrients.fertilizeCadenceDays,
                                lastDoneAt: care.fertilize.lastDoneAt),
            prune: care.prune)
        return Plant(
            plantId: plantId, commonName: commonName, species: species, nickname: nickname,
            imageRef: imageRef, toxicity: toxicity, taxonomy: taxonomy, lightingNeeds: lightingNeeds,
            fertilizerInfo: fertilizerInfo, confidence: confidence, care: newCare, carePlan: plan,
            createdAt: createdAt, downloadUrl: downloadUrl, buddy: buddy)
    }
}

extension TreeStatus {
    static let sample = TreeStatus(treesPledged: 3, milestones: ["first_plant", "fifth_plant"])
}

extension CareCard {
    static let sample = CareCard(
        species: "monstera deliciosa", commonName: "Monstera Deliciosa", toxicity: "High",
        taxonomy: Plant.sampleTaxonomy, confidence: "High")

    static let sampleUnknown = CareCard(
        species: "unknown", commonName: "Unknown Plant", toxicity: "High",
        taxonomy: nil, confidence: "Low")
}

extension CarePlan {
    static let sample = CarePlan(
        water: WaterPlan(amount: "1.5 cups", cadenceDays: 10,
                         instruction: "Water 1.5 cups every 10 days, letting the top inch of soil dry first."),
        light: LightPlan(summary: "Bright, indirect",
                         instruction: "Place it less than 6 feet from a south-facing window to ensure it receives enough light to thrive."),
        nutrients: NutrientsPlan(fertilizeCadenceDays: 30,
                                 instruction: "To replenish this plant's nutrients, repot after it doubles in size or once a year—whichever comes first."))
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
