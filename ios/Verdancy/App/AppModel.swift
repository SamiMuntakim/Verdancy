import SwiftUI
import Observation

/// Top-level app state + coordination (auth session, the shared garden, entitlement,
/// streak, notifications, and the post-purchase bloom).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, signedIn }
    enum Tab: Hashable { case today, scan, oasis, settings }

    var phase: Phase = .launching
    var selectedTab: Tab = .today
    /// Fires the one-time bloom reveal after a successful subscribe (iOS-PRD §8.4).
    var pendingBloom = false
    /// Set to the new tree total when a milestone tree is earned → transient banner.
    var treeCelebrationCount: Int?

    let auth: AuthService
    let api: APIClient
    let garden: GardenStore
    let entitlement: EntitlementService
    let streak: StreakTracker
    let notifications = NotificationService.shared

    /// Entitlement is owned by RevenueCat; the server is the real authority.
    var isSubscribed: Bool { entitlement.isSubscribed }

    private var knewPlants = false

    init(auth: AuthService) {
        self.auth = auth
        let api = APIClient(auth: auth)
        self.api = api
        let garden = GardenStore(api: api)
        self.garden = garden
        self.entitlement = EntitlementService()
        self.streak = StreakTracker()

        garden.onChanged = { [weak self] plants in
            guard let self else { return }
            let nowHasPlants = !plants.isEmpty
            let isFirstPlant = nowHasPlants && !self.knewPlants
            self.knewPlants = nowHasPlants
            self.streak.refresh(allCaughtUp: self.garden.dueItems.isEmpty)
            Task {
                if isFirstPlant { await self.notifications.requestAuthorizationIfNeeded() }
                await self.notifications.reschedule(for: plants)
                await self.reportMilestonesIfNeeded()
            }
        }
    }

    private var totalTrees: Int { (isSubscribed ? 10 : 0) + garden.trees.treesPledged }

    private let reportedKey = "verdancy.reportedMilestones"
    private var reportedMilestones: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: reportedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: reportedKey) }
    }

    /// Count-based milestones (iOS-PRD §10): first/fifth/tenth plant. Subscriber-only
    /// (§7); reported idempotently — the server dedupes.
    func reportMilestonesIfNeeded() async {
        guard isSubscribed else { return }
        let count = garden.plants.count
        var reached: [String] = []
        if count >= 1 { reached.append("first_plant") }
        if count >= 5 { reached.append("fifth_plant") }
        if count >= 10 { reached.append("tenth_plant") }

        var reported = reportedMilestones
        for id in reached where !reported.contains(id) {
            if AppConfig.useMockAuth {
                garden.trees = TreeStatus(
                    treesPledged: garden.trees.treesPledged + 1,
                    milestones: garden.trees.milestones + [id])
            } else {
                guard let status = try? await api.recordMilestone(id) else { continue }
                garden.trees = status
            }
            reported.insert(id)
            reportedMilestones = reported
            treeCelebrationCount = totalTrees
            Haptics.celebrate()
        }
    }

    func bootstrap() async {
        garden.hydrateFromSnapshot()
        knewPlants = !garden.plants.isEmpty // returning user → don't treat as first plant
        await entitlement.bootstrap()
        if await auth.isSignedIn() {
            phase = .signedIn
            if let sub = await auth.userId() { await entitlement.login(userId: sub) }
            await garden.refresh()
        } else {
            phase = .signedOut
        }
    }

    func signInWithApple() async throws {
        try await auth.signInWithApple()
        try? await api.createUser() // idempotent profile upsert (iOS-PRD §8.1)
        if let sub = await auth.userId() { await entitlement.login(userId: sub) }
        phase = .signedIn
        await garden.refresh()
    }

    /// Start the trial / purchase, then trigger the bloom on success.
    func startTrial(_ plan: EntitlementService.Plan) async throws {
        let active = try await entitlement.purchase(plan)
        if active {
            pendingBloom = true
            await reportMilestonesIfNeeded() // a subscriber with plants earns first_plant now
        }
    }

    func signOut() async {
        await auth.signOut()
        await entitlement.reset()
        SnapshotStore.clear()
        notifications.cancelAll()
        UserDefaults.standard.removeObject(forKey: reportedKey)
        garden.plants = []
        garden.trees = .empty
        knewPlants = false
        treeCelebrationCount = nil
        phase = .signedOut
    }
}
