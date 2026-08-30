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
            // Screenshot the premium state (bloomed buds, unlocked Light Meter) —
            // mock mode is not-subscribed by default so both tiers are shootable.
            if args.contains("-subscribed") {
                _app.wrappedValue.entitlement.isSubscribed = true
            }
            // A healthy care streak for the Today screenshot (mock never checks in).
            if args.contains("-signedIn") {
                _app.wrappedValue.streak.seed(24)
            }
            // The Day-0 post-purchase bloom celebration (bud blooms + trees card).
            if args.contains("-bloom") {
                _app.wrappedValue.entitlement.isSubscribed = true
                _app.wrappedValue.lastPurchasedPlan = .annual
                _app.wrappedValue.pendingBloom = true
            }
            // The Day-7 "trees planted" celebration is triggered from RootView once
            // the app has settled (presenting it during launch shifts the cover).
            if args.contains("-treesPlanted") {
                _app.wrappedValue.entitlement.isSubscribed = true
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
