import SwiftUI
import Observation

/// Top-level app state + coordination (auth session, the shared garden, entitlement).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, signedIn }
    enum Tab: Hashable { case today, scan, oasis, settings }

    var phase: Phase = .launching
    var selectedTab: Tab = .today
    /// RevenueCat entitlement (wired in Phase 4). The server is the real authority.
    var isSubscribed = false

    let auth: AuthService
    let api: APIClient
    let garden: GardenStore

    init(auth: AuthService) {
        self.auth = auth
        let api = APIClient(auth: auth)
        self.api = api
        self.garden = GardenStore(api: api)
    }

    func bootstrap() async {
        garden.hydrateFromSnapshot()
        if await auth.isSignedIn() {
            phase = .signedIn
            await garden.refresh()
        } else {
            phase = .signedOut
        }
    }

    func signInWithApple() async throws {
        try await auth.signInWithApple()
        try? await api.createUser() // idempotent profile upsert (iOS-PRD §8.1)
        phase = .signedIn
        await garden.refresh()
    }

    func signOut() async {
        await auth.signOut()
        SnapshotStore.clear()
        garden.plants = []
        garden.trees = .empty
        isSubscribed = false
        phase = .signedOut
    }
}
