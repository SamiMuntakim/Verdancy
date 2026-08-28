import SwiftUI

@main
struct VerdancyApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let auth: AuthService = AppConfig.useMockAuth ? MockAuthService() : NativeAuthService()
        _app = State(initialValue: AppModel(auth: auth))
        #if DEBUG
        // Screenshot/dev automation: `simctl launch ... -signedIn -tab oasis` jumps
        // straight to a tab in mock mode. Inert in release and outside mock mode.
        if AppConfig.useMockAuth {
            let args = CommandLine.arguments
            if args.contains("-signedIn") {
                _app = State(initialValue: AppModel(auth: MockAuthService(startSignedIn: true)))
            }
            if let i = args.firstIndex(of: "-tab"), i + 1 < args.count {
                let tab: AppModel.Tab? = [
                    "today": .today, "scan": .scan, "oasis": .oasis, "trees": .trees,
                ][args[i + 1]]
                if let tab { _app.wrappedValue.selectedTab = tab }
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.Color.leaf)
                .task { await app.bootstrap() }
                // Daily check-in on every foreground as well as launch (the server
                // no-ops a repeat within its UTC day, and `checkIn()` skips the
                // redundant round-trip).
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await app.checkIn() }
                }
        }
    }
}
