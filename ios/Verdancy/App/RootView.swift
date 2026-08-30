import SwiftUI
import StoreKit

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
                // Peak-delight moment; the system throttles how often it shows.
                requestReview()
            }
        }
        .fullScreenCover(item: $app.pendingTreesPlanted) { celebration in
            // The Day-7 moment: the annual grant's trees just went in the ground.
            TreesPlantedCelebrationView(celebration: celebration) {
                app.pendingTreesPlanted = nil
                // Money moved and trees landed — another peak, system-throttled.
                requestReview()
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
