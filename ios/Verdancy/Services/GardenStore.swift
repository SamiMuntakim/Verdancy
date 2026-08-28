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

    /// Invoked only when the user saves a plant (`insert`), never on refresh or
    /// hydrate — the hook for save-anchored moments like the first-plant
    /// notification-permission ask (iOS-PRD §12 Phase 3: request after the first
    /// plant, not on a cold launch that happens to hydrate a garden).
    var onPlantSaved: ((Plant) -> Void)?

    /// Invoked whenever fresh tree status arrives from the server (refresh or an
    /// explicit grant re-read), with the previous status for comparison — how the
    /// app notices a subscription grant landing (e.g. the Day-7 annual 10-tree
    /// grant) without ever counting trees client-side. Not fired on snapshot hydrate.
    var onTreesChanged: ((_ old: TreeStatus, _ new: TreeStatus) -> Void)?

    /// Whether the caller is a subscriber. Buddy image generation (`POST /buddy`)
    /// costs Gemini credits, so it only runs for subscribers (iOS-PRD §8/§9) — free
    /// users keep the bundled dormant seedling. Set by `AppModel`.
    var isSubscribed: () -> Bool = { false }

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
            let previousTrees = trees
            trees = fetchedTrees
            didLoadOnce = true
            SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
            onTreesChanged?(previousTrees, fetchedTrees)
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

    /// Drop everything on sign-out / session expiry — the garden belongs to the
    /// account, so it must not bleed into the next person to sign in on this device.
    func reset() {
        plants = []
        trees = .empty
        didLoadOnce = false
        SnapshotStore.clear()
    }

    /// Replace the tree status after a grant (the streak check-in) and persist it,
    /// so the forest survives a cold start offline.
    func applyTrees(_ status: TreeStatus) {
        let previous = trees
        trees = status
        SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
        onTreesChanged?(previous, status)
    }

    // MARK: Snooze ("not today")

    private static let snoozeKey = "verdancy.snoozes"

    /// `plantId-type` → date until which the task is hidden from Today. Local-only;
    /// snoozing never counts as caught up for the streak (that would game it).
    private(set) var snoozes: [String: Date] = loadSnoozes()

    private static func loadSnoozes() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: snoozeKey) ?? [:]
        let now = Date()
        return raw.compactMapValues { $0 as? Date }.filter { $0.value > now }
    }

    private func snoozeId(_ plantId: String, _ type: CareType) -> String {
        "\(plantId)-\(type.rawValue)"
    }

    /// Hide a due task until tomorrow — guilt relief, not completion.
    func snooze(plant: Plant, type: CareType) {
        let cal = Calendar.current
        guard let until = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
        else { return }
        snoozes[snoozeId(plant.plantId, type)] = until
        UserDefaults.standard.set(snoozes, forKey: Self.snoozeKey)
        Analytics.log("care_snoozed", ["type": type.rawValue])
        onChanged?(plants) // due list changed → streak/widget/reminders re-derive
    }

    // MARK: Due list

    /// Today's due list — overdue first (iOS-PRD §3.1), snoozed tasks hidden.
    var dueItems: [DueItem] { dueItems(includingSnoozed: false) }

    /// The full due list. The streak must use `includingSnoozed: true` so snoozing
    /// everything can't fake an "all caught up" day.
    func dueItems(includingSnoozed: Bool) -> [DueItem] {
        let now = Date()
        var items: [DueItem] = []
        for plant in plants {
            for type in CareType.allCases {
                guard let due = plant.care.task(for: type).nextDue(now: now), due <= now else { continue }
                if !includingSnoozed,
                   let until = snoozes[snoozeId(plant.plantId, type)], until > now { continue }
                items.append(DueItem(plant: plant, type: type, dueDate: due))
            }
        }
        return items.sorted { $0.dueDate < $1.dueDate }
    }

    /// Optimistically mark a task done, then sync; refetch on failure.
    func logCare(plant: Plant, type: CareType) async {
        Analytics.log("care_logged", ["type": type.rawValue])
        snoozes.removeValue(forKey: snoozeId(plant.plantId, type))
        UserDefaults.standard.set(snoozes, forKey: Self.snoozeKey)
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
        HealthLog.shared.removeAll(plantId: plantId)
        SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
        onChanged?(plants)
    }

    func insert(_ plant: Plant) {
        plants.removeAll { $0.plantId == plant.plantId }
        plants.insert(plant, at: 0)
        SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees))
        onChanged?(plants)
        onPlantSaved?(plant)
        ensureBuddy(for: plant)
    }

    // MARK: Plant Buddy (shared per species — PRD Appendix A)

    /// Kick off shared per-species buddy generation for a newly saved plant
    /// (iOS-PRD §9). Fire-and-forget: the bud is delight, never blocking — on any
    /// failure the bundled fallback sprite still shows. Gated on subscription so we
    /// never spend Gemini credits generating a bud a free user can't yet bloom (§8);
    /// on subscribe, `ensureBuddiesForAll()` catches up the existing garden.
    func ensureBuddy(for plant: Plant) {
        guard AppConfig.budBackendEnabled else { return } // launch: bundled sprites only
        guard !AppConfig.useMockAuth else { return }   // no backend in mock mode
        guard isSubscribed() else { return }           // subscribers only (save credits)
        guard plant.buddy?.isReady != true else { return } // already resolved
        let species = plant.species
        guard !species.isEmpty else { return }
        Task { await resolveBuddy(species: species) }
    }

    /// Resolve buds for every plant already in the garden — called the moment the
    /// user subscribes, so plants saved as free-tier seedlings bloom into a real bud.
    func ensureBuddiesForAll() {
        for plant in plants { ensureBuddy(for: plant) }
    }

    /// `POST /buddy`: `ready` → apply; `pending` (a concurrent generation) → back
    /// off and retry a few times, then leave it (a later `GET /plants` resolves it).
    /// Any error → silent; the bundled sprite remains.
    private func resolveBuddy(species: String) async {
        Analytics.log("buddy_requested")
        for attempt in 0..<4 {
            do {
                let resp = try await api.buddy(species: species)
                if resp.status == "ready", let url = resp.spriteUrl {
                    applyBuddy(Buddy(status: "ready", spriteUrl: url, styleVersion: resp.styleVersion),
                               toSpecies: species)
                    Analytics.log("buddy_ready")
                    return
                }
            } catch {
                Analytics.log("buddy_failed")
                return
            }
            if attempt < 3 { try? await Task.sleep(for: .seconds(Double((attempt + 1) * 2))) }
        }
        Analytics.log("buddy_pending") // still generating; next refresh will pick it up
    }

    /// Buds are shared per species, so apply the resolved sprite to every plant of
    /// that species in the garden.
    private func applyBuddy(_ buddy: Buddy, toSpecies species: String) {
        var changed = false
        for idx in plants.indices
        where plants[idx].species == species && plants[idx].buddy?.spriteUrl != buddy.spriteUrl {
            plants[idx] = plants[idx].withBuddy(buddy)
            changed = true
        }
        if changed { SnapshotStore.save(GardenSnapshot(plants: plants, trees: trees)) }
    }

    /// Replace a plant in place (after an edit), preserving its position.
    func update(_ plant: Plant) {
        if let idx = plants.firstIndex(where: { $0.plantId == plant.plantId }) {
            plants[idx] = plant
        } else {
            plants.insert(plant, at: 0)
        }
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
