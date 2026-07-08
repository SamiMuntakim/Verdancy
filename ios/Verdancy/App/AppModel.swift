import SwiftUI
import Observation
import WidgetKit

/// Top-level app state + coordination (auth session, the shared garden, entitlement,
/// streak, notifications, and the post-purchase bloom).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, signedIn }
    enum Tab: Hashable { case today, scan, oasis, settings }

    private static let appearanceKey = "verdancy.appearance"

    var phase: Phase = .launching
    var selectedTab: Tab = .today
    /// Fires the one-time bloom reveal after a successful subscribe (iOS-PRD §8.4).
    var pendingBloom = false
    /// Set to the new tree total when a milestone tree is earned → transient banner.
    var treeCelebrationCount: Int?
    /// Appearance override (iOS-PRD §3.4), persisted across launches.
    var appearance: Appearance =
        Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    /// The caller's invite code (fetched lazily; included in share messages).
    var referralCode: String?

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
            // Snoozed tasks still count as due for the streak (no gaming it).
            self.streak.refresh(allCaughtUp: self.garden.dueItems(includingSnoozed: true).isEmpty)
            self.publishWidgetSummary()
            Task {
                if isFirstPlant { await self.notifications.requestAuthorizationIfNeeded() }
                await self.notifications.reschedule(for: plants, streak: self.streak.current)
                await self.reportMilestonesIfNeeded()
            }
        }
    }

    private var totalTrees: Int { (isSubscribed ? 10 : 0) + garden.trees.treesPledged }

    /// Push a fresh due summary to the home-screen widget (App Group handoff).
    private func publishWidgetSummary() {
        let due = garden.dueItems
        let summary = WidgetShared.Summary(
            items: due.prefix(4).map {
                WidgetShared.Summary.Item(
                    plantName: $0.plant.displayName, task: $0.type.title,
                    systemImage: $0.type.systemImage, overdueDays: $0.overdueDays)
            },
            dueCount: due.count,
            plantCount: garden.plants.count,
            streak: streak.current,
            generatedAt: Date())
        WidgetShared.write(summary)
        WidgetCenter.shared.reloadAllTimelines()
    }

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
            Analytics.log("milestone_earned", ["id": id])
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
            await fetchReferralCode()
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
        await fetchReferralCode()
    }

    func fetchReferralCode() async {
        guard referralCode == nil else { return }
        if AppConfig.useMockAuth {
            referralCode = "PLANT4U2"
        } else {
            referralCode = try? await api.referralCode()
        }
    }

    /// Start the trial / purchase, then trigger the bloom on success.
    func startTrial(_ plan: EntitlementService.Plan) async throws {
        let active = try await entitlement.purchase(plan)
        if active {
            Analytics.log("trial_started", ["plan": plan == .annual ? "annual" : "monthly"])
            pendingBloom = true
            await reportMilestonesIfNeeded() // a subscriber with plants earns first_plant now
        }
    }

    func setAppearance(_ value: Appearance) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: AppModel.appearanceKey)
    }

    /// Full account deletion (App Store 5.1.1(v)): the backend removes data + the
    /// Cognito identity, then we clear local state.
    func deleteAccount() async throws {
        if !AppConfig.useMockAuth { try await api.deleteUser() }
        await signOut()
    }

    func signOut() async {
        await auth.signOut()
        await entitlement.reset()
        SnapshotStore.clear()
        HealthLog.shared.clear()
        WidgetShared.clear()
        WidgetCenter.shared.reloadAllTimelines()
        notifications.cancelAll()
        UserDefaults.standard.removeObject(forKey: reportedKey)
        garden.plants = []
        garden.trees = .empty
        knewPlants = false
        treeCelebrationCount = nil
        referralCode = nil
        phase = .signedOut
    }
}
