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
            }
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
        if active { pendingBloom = true }
    }

    func signOut() async {
        await auth.signOut()
        await entitlement.reset()
        SnapshotStore.clear()
        notifications.cancelAll()
        garden.plants = []
        garden.trees = .empty
        knewPlants = false
        phase = .signedOut
    }
}
