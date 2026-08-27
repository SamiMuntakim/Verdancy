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
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(
                        Theme.leafGradient,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .shadow(color: Theme.Color.leaf.opacity(0.3), radius: 18, y: 8)
                Text("Verdancy")
                    .font(.title.weight(.bold))
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
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppModel.Tab.settings)
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
