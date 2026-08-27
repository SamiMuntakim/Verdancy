import SwiftUI

@main
struct VerdancyApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let auth: AuthService = AppConfig.useMockAuth ? MockAuthService() : NativeAuthService()
        _app = State(initialValue: AppModel(auth: auth))
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
