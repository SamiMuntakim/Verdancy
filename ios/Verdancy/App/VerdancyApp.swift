import SwiftUI

@main
struct VerdancyApp: App {
    @State private var app: AppModel

    init() {
        let auth: AuthService = AppConfig.useMockAuth ? MockAuthService() : NativeAppleAuthService()
        _app = State(initialValue: AppModel(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.Color.leaf)
                .task { await app.bootstrap() }
        }
    }
}
