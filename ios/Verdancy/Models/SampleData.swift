import Foundation

private func daysAgo(_ n: Int) -> String {
    ISO.string(Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date())
}

extension Plant {
    static let sampleTaxonomy = Taxonomy(
        family: "Araceae", genus: "Monstera", species: "deliciosa", cultivar: "Albo")

    private static let readyBuddy = Buddy(status: "ready", spriteUrl: nil, styleVersion: 1)

    /// Every mock garden plant shares the `.sample` plan (water every 10 days), so a
    /// plant's `care` cadences match the plan its detail shows. Due state is driven
    /// purely by `lastDoneAt`, which keeps the Today list deterministic.
    private static func careMap(waterDaysAgo: Int, fertilizeDaysAgo: Int) -> CareMap {
        CareMap(
            water: CareTask(cadenceDays: 10, lastDoneAt: daysAgo(waterDaysAgo)),
            fertilize: CareTask(cadenceDays: 30, lastDoneAt: daysAgo(fertilizeDaysAgo)),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil))
    }

    // The mock garden mirrors the six bundled screenshot photos (seeded into the
    // image cache by `ScreenshotSupport` in DEBUG), each a distinct bud archetype.

    static let sample = Plant(
        plantId: "p1", commonName: "Monstera", species: "monstera deliciosa", nickname: "Monty",
        imageRef: "u/mock/p/p1/a.jpg", toxicity: "High", taxonomy: sampleTaxonomy,
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High", archetype: "broadleaf",
        // Water a day past due — Today shows a "1d late" row and Monty's buddy droops.
        care: careMap(waterDaysAgo: 11, fertilizeDaysAgo: 10),
        carePlan: .sample, createdAt: daysAgo(40), downloadUrl: nil, buddy: readyBuddy)

    static let sampleOrchid = Plant(
        plantId: "p9", commonName: "Moth Orchid", species: "phalaenopsis", nickname: nil,
        imageRef: "u/mock/p/p9/a.jpg", toxicity: "None",
        taxonomy: Taxonomy(family: "Orchidaceae", genus: "Phalaenopsis", species: "", cultivar: nil),
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High", archetype: "orchid",
        care: careMap(waterDaysAgo: 10, fertilizeDaysAgo: 9), // water due today, pet-safe
        carePlan: .sample, createdAt: daysAgo(24), downloadUrl: nil, buddy: readyBuddy)

    static let sampleFern = Plant(
        plantId: "p8", commonName: "Boston Fern", species: "nephrolepis exaltata", nickname: nil,
        imageRef: "u/mock/p/p8/a.jpg", toxicity: "None",
        taxonomy: Taxonomy(family: "Nephrolepidaceae", genus: "Nephrolepis", species: "exaltata", cultivar: nil),
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High", archetype: "fern",
        care: careMap(waterDaysAgo: 10, fertilizeDaysAgo: 12), // water due today, pet-safe
        carePlan: .sample, createdAt: daysAgo(18), downloadUrl: nil, buddy: readyBuddy)

    static let sampleSnake = Plant(
        plantId: "p2", commonName: "Snake Plant", species: "dracaena trifasciata", nickname: nil,
        imageRef: "u/mock/p/p2/a.jpg", toxicity: "Low",
        taxonomy: Taxonomy(family: "Asparagaceae", genus: "Dracaena", species: "trifasciata", cultivar: nil),
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High", archetype: "upright",
        care: careMap(waterDaysAgo: 3, fertilizeDaysAgo: 6), // all caught up
        carePlan: .sample, createdAt: daysAgo(20), downloadUrl: nil, buddy: readyBuddy)

    static let samplePothos = Plant(
        plantId: "p6", commonName: "Golden Pothos", species: "epipremnum aureum", nickname: "Neon",
        imageRef: "u/mock/p/p6/a.jpg", toxicity: "High",
        taxonomy: Taxonomy(family: "Araceae", genus: "Epipremnum", species: "aureum", cultivar: nil),
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High", archetype: "trailing",
        care: careMap(waterDaysAgo: 5, fertilizeDaysAgo: 31), // feeding a day late
        carePlan: .sample, createdAt: daysAgo(10), downloadUrl: nil, buddy: readyBuddy)

    static let sampleSucculent = Plant(
        plantId: "p10", commonName: "Echeveria", species: "echeveria elegans", nickname: "Pebble",
        imageRef: "u/mock/p/p10/a.jpg", toxicity: "None",
        taxonomy: Taxonomy(family: "Crassulaceae", genus: "Echeveria", species: "elegans", cultivar: nil),
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "High", archetype: "succulent",
        care: careMap(waterDaysAgo: 2, fertilizeDaysAgo: 4), // all caught up
        carePlan: .sample, createdAt: daysAgo(6), downloadUrl: nil, buddy: readyBuddy)

    static let sampleUnknown = Plant(
        plantId: "p3", commonName: "Unknown Plant", species: "unknown", nickname: "Mystery",
        imageRef: "u/mock/p/p3/a.jpg", toxicity: "High", taxonomy: nil,
        lightingNeeds: nil, fertilizerInfo: nil, confidence: "Low", archetype: nil,
        care: CareMap(
            water: CareTask(cadenceDays: nil, lastDoneAt: nil),
            fertilize: CareTask(cadenceDays: nil, lastDoneAt: nil),
            prune: CareTask(cadenceDays: nil, lastDoneAt: nil)),
        carePlan: nil, createdAt: daysAgo(2), downloadUrl: nil, buddy: nil)

    static let samples: [Plant] = [
        sample, sampleOrchid, sampleFern, sampleSnake, samplePothos, sampleSucculent,
    ]

    /// Build a local Plant from an identify result (used by mock-mode save). Care
    /// starts empty — the personalized plan fills it in (mock-mode synthesizes one).
    static func mock(from card: CareCard, nickname: String?) -> Plant {
        Plant(
            plantId: UUID().uuidString, commonName: card.commonName, species: card.species,
            nickname: nickname, imageRef: "u/mock/p/\(UUID().uuidString)/a.jpg",
            toxicity: card.toxicity, taxonomy: card.taxonomy, lightingNeeds: nil,
            fertilizerInfo: nil, confidence: card.confidence, archetype: card.archetype,
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
            fertilizerInfo: fertilizerInfo, confidence: confidence, archetype: archetype,
            care: newCare, carePlan: plan,
            createdAt: createdAt, downloadUrl: downloadUrl, buddy: buddy)
    }
}

extension CommunityForest {
    /// The whole-app forest for mock/offline runs — a real Tree-Nation profile feed
    /// (species, project, country per line) so the Community tab renders without the
    /// backend proxy.
    static let sample = CommunityForest(
        totalTrees: 48213, co2Tons: 964.3,
        profileUrl: "https://tree-nation.com/profile/verdancy",
        trees: [
            CommunityTree(
                id: 1, quantity: 3,
                message: "3 Grey Mangroves planted in the Usambara Biodiversity Reserve, Tanzania",
                image: nil, plantedAt: "2026-08-28T10:12:00.000Z",
                certificateUrl: "https://tree-nation.com/certificate/1", collectUrl: nil),
            CommunityTree(
                id: 2, quantity: 1,
                message: "A Coffee tree planted in the Mount Kenya Reforestation, Kenya",
                image: nil, plantedAt: "2026-08-28T08:40:00.000Z",
                certificateUrl: "https://tree-nation.com/certificate/2", collectUrl: nil),
            CommunityTree(
                id: 3, quantity: 8,
                message: "8 Red Mangroves planted in the Eden Reforestation, Madagascar",
                image: nil, plantedAt: "2026-08-27T16:05:00.000Z",
                certificateUrl: "https://tree-nation.com/certificate/3", collectUrl: nil),
            CommunityTree(
                id: 4, quantity: 2,
                message: "2 Guanacaste trees planted in the Tropical Forest, Costa Rica",
                image: nil, plantedAt: "2026-08-27T11:20:00.000Z",
                certificateUrl: "https://tree-nation.com/certificate/4", collectUrl: nil),
        ])
}

extension TreeStatus {
    static let sample = TreeStatus(
        treesPledged: 3, milestones: ["first_plant", "fifth_plant"],
        planted: [
            PlantedTree(
                collectUrl: "https://tree-nation.com/collect/sample-1",
                certificateUrl: "https://tree-nation.com/certificate/sample-1",
                speciesName: "Avicennia marina", commonName: "Grey Mangrove",
                speciesImage: "u/mock/tree/mangrove.jpg",
                projectName: "Usambara Biodiversity Reserve",
                projectUrl: "https://tree-nation.com/projects/sample/updates",
                country: "Tanzania", lifeTimeCo2: 10,
                reason: "streak_30", plantedAt: "2026-08-20T09:12:00.000Z"),
            PlantedTree(
                collectUrl: "https://tree-nation.com/collect/sample-2",
                certificateUrl: "https://tree-nation.com/certificate/sample-2",
                speciesName: "Vachellia tortilis", commonName: "Umbrella Thorn Acacia",
                speciesImage: "u/mock/tree/acacia.jpg",
                projectName: "Mount Kenya Reforestation",
                country: "Kenya", lifeTimeCo2: 100,
                reason: "referral_joined", plantedAt: "2026-08-06T17:40:00.000Z"),
        ])
}

extension CareCard {
    static let sample = CareCard(
        species: "monstera deliciosa", commonName: "Monstera Deliciosa", toxicity: "High",
        taxonomy: Plant.sampleTaxonomy, confidence: "High", archetype: "broadleaf")

    static let sampleUnknown = CareCard(
        species: "unknown", commonName: "Unknown Plant", toxicity: "High",
        taxonomy: nil, confidence: "Low", archetype: nil)

    /// Toxic, high-confidence — the pet-safety hero (identify shot #2).
    static let samplePothos = CareCard(
        species: "epipremnum aureum", commonName: "Golden Pothos", toxicity: "High",
        taxonomy: Taxonomy(family: "Araceae", genus: "Epipremnum",
                           species: "aureum", cultivar: nil),
        confidence: "High", archetype: "trailing")

    /// A pet-safe, high-confidence result — mirrors the onboarding hero and shows
    /// the positive safety verdict (used by the scan-result demo hook / previews).
    static let sampleSafe = CareCard(
        species: "calathea orbifolia", commonName: "Calathea Orbifolia", toxicity: "None",
        taxonomy: Taxonomy(family: "Marantaceae", genus: "Calathea",
                           species: "orbifolia", cultivar: nil),
        confidence: "High", archetype: "broadleaf")
}

extension CarePlan {
    static let sample = CarePlan(
        water: WaterPlan(amount: "1.5 cups", cadenceDays: 10,
                         instruction: "Water 1.5 cups every 10 days, letting the top inch of soil dry first."),
        light: LightPlan(summary: "Bright, indirect",
                         instruction: "Place it less than 6 feet from a south-facing window to ensure it receives enough light to thrive."),
        nutrients: NutrientsPlan(fertilizeCadenceDays: 30,
                                 instruction: "A balanced liquid feed at half strength through spring and summer. Skip it in winter."))
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
