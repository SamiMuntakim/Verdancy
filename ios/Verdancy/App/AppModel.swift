import SwiftUI
import Observation
import WidgetKit

/// Top-level app state + coordination (auth session, the shared garden, entitlement,
/// streak, notifications, and the post-purchase bloom).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, signedIn }
    enum Tab: Hashable { case today, scan, oasis, trees }

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
    /// Which plan the last successful purchase was — lets the bloom's tree card
    /// speak honestly (annual: 10 trees reserved for Day 7; monthly: 1/month now).
    var lastPurchasedPlan: EntitlementService.Plan?
    /// Set when a tree is earned (milestone or care streak) → transient banner.
    var treeCelebration: TreeCelebration?
    /// Fires the full-screen "you just planted 10 real trees" moment when the
    /// annual subscription's grant lands (the Day-7 converting payment). Set by
    /// `handleTreesChanged`, presented from RootView, celebrated exactly once.
    var pendingTreesPlanted: TreesPlantedCelebration?
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

    /// A free garden is full once it holds `freeGardenLimit` plants — the moment to
    /// offer the trial to someone who has now built (and would lose) a collection.
    /// Subscribers are never capped.
    var freeGardenFull: Bool {
        !isSubscribed && garden.plants.count >= AppConfig.freeGardenLimit
    }

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

        garden.onTreesChanged = { [weak self] old, new in
            self?.handleTreesChanged(old: old, new: new)
        }

        garden.onChanged = { [weak self] plants in
            guard let self else { return }
            // Snoozed tasks still count as due for the streak (no gaming it).
            self.streak.refresh(allCaughtUp: self.garden.dueItems(includingSnoozed: true).isEmpty)
            self.publishWidgetSummary()
            Task {
                await self.notifications.reschedule(for: plants, streak: self.streak.current)
            }
        }

        // The permission ask is anchored to the user's own save action (their first
        // plant), never to a refresh that happens to bring plants down — a cold
        // launch must never open with a permission sheet.
        garden.onPlantSaved = { [weak self] _ in
            guard let self, self.garden.plants.count == 1 else { return }
            Task {
                await self.notifications.requestAuthorizationIfNeeded()
                await self.notifications.reschedule(
                    for: self.garden.plants, streak: self.streak.current)
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
            lastPurchasedPlan = plan
            // Now that they're a subscriber, generate the real bud(s) so the bloom
            // opens into their plant's own buddy (gated until here to save credits).
            garden.ensureBuddiesForAll()
            pendingBloom = true
            awaitGrantedTrees()
            // Keep the paywall's "Day 5 — we remind you" promise for the trial.
            if plan == .annual { await notifications.scheduleTrialReminder(inDays: 5) }
        }
    }

    /// The annual grant's 10 trees are written by the RevenueCat webhook, which
    /// lands server-to-server a moment AFTER the purchase call returns — so a
    /// single immediate read almost always sees the old count, and the user is
    /// told "0 trees" seconds after paying for ten. Poll briefly instead, in the
    /// background so the bloom isn't held up, and stop the moment the grant shows.
    /// Nothing arrives for a monthly plan (or a sandbox purchase, which never
    /// funds trees), so this just times out quietly.
    private func awaitGrantedTrees() {
        let before = garden.trees.treesPledged
        Task { [weak self] in
            for delay in [1.0, 2.0, 3.0, 5.0, 8.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                guard let status = try? await self.api.trees() else { continue }
                if status.treesPledged > before {
                    self.garden.applyTrees(status)
                    return
                }
            }
        }
    }

    // MARK: - Subscription tree grants (the Day-7 moment)

    /// Milestone ids of subscription grants (`sub_` prefix, written by the
    /// RevenueCat webhook) this device has already seen — so a grant is celebrated
    /// exactly once, and never re-celebrated on later refreshes.
    private static let seenSubGrantsKey = "verdancy.subGrants.seen"

    /// Celebrate a subscription tree grant the moment it shows up in fresh server
    /// tree status. The annual grant lands with the Day-7 converting payment (the
    /// webhook funds trees only when money moves), so the client's job is purely to
    /// NOTICE it: a new `sub_` milestone plus a jump of the full annual grant means
    /// the 10 trees were just planted → the full-screen celebration. A smaller jump
    /// (monthly's tree) gets the transient banner. The first-ever status for an
    /// account only baselines, so a reinstall or second device never replays
    /// history as if it just happened.
    private func handleTreesChanged(old: TreeStatus, new: TreeStatus) {
        let subGrants = Set(new.milestones.filter { $0.hasPrefix("sub_") })
        let defaults = UserDefaults.standard
        guard let seenList = defaults.stringArray(forKey: Self.seenSubGrantsKey) else {
            defaults.set(Array(subGrants), forKey: Self.seenSubGrantsKey)
            return
        }
        let unseen = subGrants.subtracting(seenList)
        guard !unseen.isEmpty else { return }
        defaults.set(Array(subGrants.union(seenList)), forKey: Self.seenSubGrantsKey)

        let jump = new.treesPledged - old.treesPledged
        guard jump > 0 else { return }
        if jump >= AppConfig.annualTreeGrant {
            pendingTreesPlanted = TreesPlantedCelebration(count: jump, total: new.treesPledged)
            Analytics.log("annual_trees_celebrated")
            Haptics.celebrate()
        } else if !pendingBloom {
            // Monthly's single tree: the banner is the right size. Skipped while the
            // bloom reveal is up — they're already mid-celebration.
            treeCelebration = TreeCelebration(total: new.treesPledged, streakDays: nil)
            Haptics.celebrate()
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
        notifications.clearTrialReminder()
        streak.reset()
        garden.reset()
        lastCheckinDay = nil
        treeCelebration = nil
        lastPurchasedPlan = nil
        pendingTreesPlanted = nil
        UserDefaults.standard.removeObject(forKey: Self.seenSubGrantsKey)
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

/// A landed subscription grant — the annual plan's trees, planted by the Day-7
/// converting payment (iOS-PRD §10). `count` is how many this grant planted,
/// `total` the whole forest after it.
struct TreesPlantedCelebration: Equatable, Identifiable {
    let count: Int
    let total: Int

    var id: String { "\(count)-\(total)" }
}
