import Foundation
import Observation

/// A single care task that's due now (computed on-device, iOS-PRD §3.1/§4).
struct DueItem: Identifiable {
    let plant: Plant
    let type: CareType
    let dueDate: Date

    var id: String { "\(plant.plantId)-\(type.rawValue)" }
    var overdueDays: Int {
        max(0, Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0)
    }
}

/// Shared garden state — the source the Today and My Oasis tabs render from.
/// Hydrates instantly from the disk snapshot, then refreshes ("stale-while-revalidate").
@Observable
@MainActor
final class GardenStore {
    private let api: APIClient

    var plants: [Plant] = []
    var trees: TreeStatus = .empty
    var isLoading = false
    var didLoadOnce = false

    /// Invoked after the plant list changes (refresh/insert/care/remove) so the app
    /// can update the streak + reschedule reminders. Does NOT fire on snapshot hydrate.
    var onChanged: (([Plant]) -> Void)?

    init(api: APIClient) {
        self.api = api
    }

    func hydrateFromSnapshot() {
        guard let snap = SnapshotStore.load() else { return }
        plants = snap.plants
        trees = snap.trees
        didLoadOnce = true
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let plantsCall = api.listPlants()
            async let treesCall = api.trees()
            let (fetchedPlants, fetchedTrees) = try await (plantsCall, treesCall)
            plants = fetchedPlants
            trees = fetchedTrees
            didLoadOnce = true
            SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
        } catch {
            // In mock/offline mode, fall back to sample data so the UI is runnable.
            if AppConfig.useMockAuth, plants.isEmpty {
                plants = Plant.samples
                trees = .sample
                didLoadOnce = true
            }
        }
        onChanged?(plants)
    }

    /// Today's due list — overdue first (iOS-PRD §3.1).
    var dueItems: [DueItem] {
        let now = Date()
        var items: [DueItem] = []
        for plant in plants {
            for type in CareType.allCases {
                guard let due = plant.care.task(for: type).nextDue(now: now), due <= now else { continue }
                items.append(DueItem(plant: plant, type: type, dueDate: due))
            }
        }
        return items.sorted { $0.dueDate < $1.dueDate }
    }

    /// Optimistically mark a task done, then sync; refetch on failure.
    func logCare(plant: Plant, type: CareType) async {
        applyCareLocally(plantId: plant.plantId, type: type, at: Date())
        onChanged?(plants) // optimistic — update streak + reminders immediately
        do {
            try await api.logCare(plantId: plant.plantId, type: type)
            SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
        } catch {
            await refresh() // fires onChanged again on rollback
        }
    }

    func remove(plantId: String) async throws {
        try await api.deletePlant(plantId: plantId)
        plants.removeAll { $0.plantId == plantId }
        SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
        onChanged?(plants)
    }

    func insert(_ plant: Plant) {
        plants.removeAll { $0.plantId == plant.plantId }
        plants.insert(plant, at: 0)
        SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
        onChanged?(plants)
    }

    private func applyCareLocally(plantId: String, type: CareType, at date: Date) {
        guard let idx = plants.firstIndex(where: { $0.plantId == plantId }) else { return }
        let stamp = ISO.string(date)
        let care = plants[idx].care
        func bump(_ task: CareTask) -> CareTask { CareTask(cadenceDays: task.cadenceDays, lastDoneAt: stamp) }
        let updated = CareMap(
            water: type == .water ? bump(care.water) : care.water,
            fertilize: type == .fertilize ? bump(care.fertilize) : care.fertilize,
            prune: type == .prune ? bump(care.prune) : care.prune)
        plants[idx] = plants[idx].withCare(updated)
    }
}
