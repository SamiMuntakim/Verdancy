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
    /// A brand-new account is in the first-run flow (iOS-PRD §8.2): sign up →
    /// guided first scan → seedling reveal → paywall. While true, RootView shows the
    /// `FirstRunView` coordinator instead of the tab bar. Cleared once they finish
    /// (subscribe & bloom) or choose "maybe later".
    var firstRunActive = false
    /// Fires the one-time bloom reveal after a successful subscribe (iOS-PRD §8.4).
    var pendingBloom = false
    /// Set when a tree is earned (milestone or care streak) → transient banner.
    var treeCelebration: TreeCelebration?
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

        // Buddy image generation costs Gemini credits, so only subscribers trigger
        // it (iOS-PRD §9): free users keep the bundled dormant seedling until they
        // subscribe, at which point the bloom has a real bud to open into.
        garden.isSubscribed = { [weak self] in self?.isSubscribed ?? false }

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
            }
        }
    }

    /// Trees come from the server and nowhere else. The count must never include a
    /// client-side guess: the annual grant lands via the RevenueCat webhook (monthly
    /// grants none, and sandbox purchases grant none at all), so adding a local +10
    /// on `isSubscribed` would show trees nobody funded — and double-count once the
    /// real grant arrives.
    private var totalTrees: Int { garden.trees.treesPledged }

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

    // MARK: - Onboarding

    private static let hasOnboardedKey = "verdancy.hasOnboarded"

    /// Whether the intro slides + quiz have been completed on this device. Survives
    /// sign-out on purpose: the quiz is a first-impression tool, not a login step.
    static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: hasOnboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasOnboardedKey) }
    }

    // MARK: - Session

    /// Return to the sign-in gate when the session is gone.
    ///
    /// A refresh token that has expired or been revoked can't be recovered, and
    /// `APIClient` needs a token *before* it sends anything — so without this the
    /// app sits on the signed-in UI making no network calls at all, showing stale
    /// plants whose presigned image URLs have long since expired. `NativeAuthService`
    /// drops the dead tokens, so this just reflects that in the UI. Transient
    /// failures keep their tokens and are left alone.
    private func enforceSession() async {
        guard phase == .signedIn, !AppConfig.useMockAuth else { return }
        guard await auth.isSignedIn() == false else { return }
        garden.reset()
        streak.reset()
        phase = .signedOut
    }

    // MARK: - Daily check-in (POST /checkin)

    /// The UTC day of the last successful check-in. The server keys the streak on
    /// its own UTC date, so this dedupe must use UTC too — a local-day key would
    /// skip the first foreground after a UTC rollover.
    private var lastCheckinDay: Date?
    private var checkinInFlight = false

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return cal
    }()

    /// `POST /checkin` on every launch and foreground: the server advances the care
    /// streak from its own UTC date and tells us whether that earned a tree. Repeat
    /// calls in a day are a safe no-op server-side; we still skip the redundant
    /// round-trip. Failures are silent — the local streak simply stands.
    func checkIn() async {
        guard phase == .signedIn, !AppConfig.useMockAuth, !checkinInFlight else { return }
        let today = Self.utcCalendar.startOfDay(for: Date())
        guard lastCheckinDay != today else { return }
        checkinInFlight = true
        defer { checkinInFlight = false }

        guard let result = try? await api.checkin() else {
            await enforceSession() // a dead session surfaces here on every foreground
            return
        }
        lastCheckinDay = today
        streak.applyServer(result.streak)
        publishWidgetSummary()
        await notifications.reschedule(for: garden.plants, streak: streak.current)

        guard result.treeGranted else { return }
        // The grant lands server-side, so re-read the authoritative tree status
        // rather than incrementing a local counter.
        if let status = try? await api.trees() { garden.applyTrees(status) }
        treeCelebration = TreeCelebration(total: totalTrees, streakDays: result.streak)
        Analytics.log("streak_tree_earned", ["streak": "\(result.streak)"])
        Haptics.celebrate()
    }

    func bootstrap() async {
        garden.hydrateFromSnapshot()
        knewPlants = !garden.plants.isEmpty // returning user → don't treat as first plant
        await entitlement.bootstrap()
        if await auth.isSignedIn() {
            phase = .signedIn
            if let sub = await auth.userId() { await entitlement.login(userId: sub) }
            await garden.refresh()
            // `refresh()` swallows its errors, so an expired session would otherwise
            // leave us signed-in-looking with stale data and dead image URLs.
            await enforceSession()
            guard phase == .signedIn else { return }
            await fetchReferralCode()
            await checkIn()
        } else {
            phase = .signedOut
        }
    }

    func signInWithApple() async throws {
        try await auth.signInWithApple()
        await completeSignIn()
    }

    func signInWithGoogle() async throws {
        try await auth.signInWithGoogle()
        await completeSignIn()
    }

    func signInWithEmail(_ email: String, password: String) async throws {
        try await auth.signInWithEmail(email, password: password)
        await completeSignIn()
    }

    /// Shared post-sign-in setup, whichever provider was used.
    private func completeSignIn() async {
        // Reaching a signed-in state means the intro + quiz have been answered on
        // this device; signing out (or a session expiring) shouldn't make the user
        // sit through them again just to reach the sign-in buttons.
        AppModel.hasOnboarded = true
        try? await api.createUser() // idempotent profile upsert (iOS-PRD §8.1)
        if let sub = await auth.userId() { await entitlement.login(userId: sub) }
        phase = .signedIn
        await garden.refresh()
        await fetchReferralCode()
        // A fresh account with an empty garden enters the guided first-run flow
        // (scan → seedling → paywall). A returning user (reinstall / second device)
        // whose garden already has plants, or anyone who's finished it before, skips
        // straight to the app.
        firstRunActive = !firstRunComplete && garden.plants.isEmpty
        await checkIn()
    }

    private static let firstRunKey = "verdancy.firstRunComplete"
    private var firstRunComplete: Bool {
        get { UserDefaults.standard.bool(forKey: Self.firstRunKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.firstRunKey) }
    }

    /// Leave the first-run flow into the main app — whether they subscribed (the
    /// bloom just played) or chose "maybe later". Idempotent, so the bloom's
    /// completion can call it unconditionally.
    func completeFirstRun() {
        guard firstRunActive || !firstRunComplete else { return }
        firstRunComplete = true
        firstRunActive = false
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
            // Now that they're a subscriber, generate the real bud(s) so the bloom
            // opens into their plant's own buddy (gated until here to save credits).
            garden.ensureBuddiesForAll()
            pendingBloom = true
            // The annual grant's 10 trees arrive server-side via the RevenueCat
            // webhook, so re-read rather than assuming anything locally.
            if let status = try? await api.trees() { garden.applyTrees(status) }
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
        streak.reset()
        garden.reset()
        knewPlants = false
        lastCheckinDay = nil
        treeCelebration = nil
        referralCode = nil
        phase = .signedOut
    }
}

/// A tree the user just earned — milestone or care streak (iOS-PRD §10). Carries
/// `streakDays` when the check-in streak is what earned it, so the banner can name
/// the reason instead of showing a generic total.
struct TreeCelebration: Equatable, Identifiable {
    let total: Int
    let streakDays: Int?

    var id: String { "\(total)-\(streakDays ?? -1)" }
}
