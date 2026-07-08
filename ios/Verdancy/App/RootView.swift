import SwiftUI

/// Auth gate: launch → sign-in → the tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.phase {
            case .launching: LaunchView()
            case .signedOut: OnboardingView()
            case .signedIn: MainTabView()
            }
        }
        .preferredColorScheme(app.appearance.colorScheme)
        .animation(.smooth, value: app.phase)
        .fullScreenCover(isPresented: $app.pendingBloom) {
            BloomCelebrationView { app.pendingBloom = false }
        }
        .overlay(alignment: .top) {
            if let total = app.treeCelebrationCount {
                TreeEarnedBanner(total: total)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        app.treeCelebrationCount = nil
                    }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: app.treeCelebrationCount)
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
