import SwiftUI
import StoreKit

/// Gate for Apple's native rating prompt (App Store Review Guideline 5.6.3): a
/// rating may never be requested on first launch or during onboarding — only
/// after the user has genuinely engaged. We therefore allow the prompt at most
/// once, and only after the app has been installed for a few days. That install
/// age structurally rules out the first-launch and the day-0 first-run flow
/// (where an annual purchase can fire a bloom/trees celebration seconds after
/// onboarding), so a delight moment routed through here can never ask too early.
/// The system additionally rate-limits whether the dialog actually shows.
enum ReviewGate {
    private static let firstLaunchKey = "verdancy.review.firstLaunch"
    private static let promptedKey = "verdancy.review.prompted"
    /// Real engagement must accrue before we ask — never day-0 onboarding.
    private static let minInstallAge: TimeInterval = 3 * 24 * 60 * 60

    /// Record the first real launch, once. Safe to call on every launch.
    static func registerLaunch() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: firstLaunchKey) == nil {
            defaults.set(Date(), forKey: firstLaunchKey)
        }
    }

    /// True when a peak-delight moment may ask for a review: installed long
    /// enough to exclude first launch / onboarding, and not already asked.
    /// Marks the request so the prompt is only ever requested once.
    static func consume() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptedKey) else { return false }
        let first = defaults.object(forKey: firstLaunchKey) as? Date ?? Date()
        guard Date().timeIntervalSince(first) >= minInstallAge else { return false }
        defaults.set(true, forKey: promptedKey)
        return true
    }
}

/// Auth gate: launch → sign-in → the tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.phase {
            case .launching: LaunchView()
            case .signedOut: OnboardingView()
            case .signedIn:
                // A brand-new account runs the guided first-run flow (scan →
                // seedling → paywall) before landing in the tab bar (iOS-PRD §8.2).
                if app.firstRunActive { FirstRunView() } else { MainTabView() }
            }
        }
        .preferredColorScheme(app.appearance.colorScheme)
        .animation(.smooth, value: app.phase)
        .animation(.smooth, value: app.firstRunActive)
        .fullScreenCover(isPresented: $app.pendingBloom) {
            // Bloom into the user's most recent plant's real bud (the one they saved
            // in onboarding), not a generic sprite.
            BloomCelebrationView(plant: app.garden.plants.first) {
                app.pendingBloom = false
                // If this bloom capped the first-run flow, leave it for the tab bar.
                app.completeFirstRun()
                // Peak-delight moment — but only once the user is past onboarding
                // and has engaged for a few days (Guideline 5.6.3); the system
                // additionally throttles how often it shows.
                if ReviewGate.consume() { requestReview() }
            }
        }
        .fullScreenCover(item: $app.pendingTreesPlanted) { celebration in
            // The Day-7 moment: the annual grant's trees just went in the ground.
            TreesPlantedCelebrationView(celebration: celebration) {
                app.pendingTreesPlanted = nil
                // Money moved and trees landed — another peak, gated so it never
                // fires during onboarding/first-run (Guideline 5.6.3).
                if ReviewGate.consume() { requestReview() }
            }
        }
        .overlay(alignment: .top) {
            if let celebration = app.treeCelebration {
                TreeEarnedBanner(celebration: celebration)
                    .task(id: celebration.id) {
                        try? await Task.sleep(for: .seconds(3))
                        app.treeCelebration = nil
                    }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: app.treeCelebration)
        #if DEBUG
        // Screenshot: present the Day-7 celebration once the app has settled, so the
        // full-screen cover isn't laid out mid-launch (which shifts it).
        .task {
            guard AppConfig.useMockAuth,
                  CommandLine.arguments.contains("-treesPlanted") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            app.pendingTreesPlanted = TreesPlantedCelebration(count: 10, total: 10)
        }
        #endif
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                BrandMark(size: 92)
                Text("Verdancy")
                    .font(.title.weight(.bold))
                    .kerning(0.2)
                    .foregroundStyle(Theme.Color.textPrimary)
                ProgressView().tint(Theme.Color.leaf)
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
                .tag(AppModel.Tab.today)
            SmartScanView()
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                .tag(AppModel.Tab.scan)
            MyOasisView()
                .tabItem { Label("My Oasis", systemImage: "leaf.fill") }
                .tag(AppModel.Tab.oasis)
            TreesView()
                .tabItem { Label("Trees", systemImage: "tree.fill") }
                .tag(AppModel.Tab.trees)
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
