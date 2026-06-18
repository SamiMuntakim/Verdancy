import SwiftUI

@main
struct VerdancyApp: App {
    @State private var app: AppModel

    init() {
        let auth: AuthService
        if AppConfig.useMockAuth {
            auth = MockAuthService()
        } else {
            AmplifyAuthService.configure()
            auth = AmplifyAuthService()
        }
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
