import SwiftUI

/// Auth gate: launch → sign-in → the tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching: LaunchView()
            case .signedOut: SignInView()
            case .signedIn: MainTabView()
            }
        }
        .animation(.smooth, value: app.phase)
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "leaf.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.Color.leaf)
                Text("Verdancy")
                    .font(.title.weight(.semibold))
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
