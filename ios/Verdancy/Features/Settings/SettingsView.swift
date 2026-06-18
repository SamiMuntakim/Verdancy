import SwiftUI

/// Settings (iOS-PRD §3.4). Sign-out + paywall are live; reminders, appearance,
/// referral, and account deletion are wired in later phases (deletion needs the
/// backend `DELETE /users`, iOS-PRD §13).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showPaywall = false
    @State private var remindersOn = NotificationService.shared.remindersEnabled

    private var totalTrees: Int {
        (app.isSubscribed ? 10 : 0) + app.garden.trees.treesPledged
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Plan", value: app.isSubscribed ? "Subscriber" : "Free")
                    Button("Sign out") { Task { await app.signOut() } }
                    Button("Delete account", role: .destructive) {}
                }

                Section("Subscription") {
                    LabeledContent("Status", value: app.isSubscribed ? "Active" : "Not subscribed")
                    if !app.isSubscribed {
                        Button("See plans") { showPaywall = true }
                    }
                    Button("Restore purchases") { Task { await app.entitlement.restore() } }
                }

                Section("Your impact") {
                    LabeledContent("Trees pledged", value: "\(totalTrees)")
                    ForEach(app.garden.trees.milestones, id: \.self) { milestone in
                        Label(milestone.replacingOccurrences(of: "_", with: " ").capitalized,
                              systemImage: "tree.fill")
                    }
                    if let url = URL(string: "https://verdancy.app/trees") {
                        Link("View the public tree counter", destination: url)
                    }
                }

                Section("Grow the forest") {
                    Button {
                        // Phase 5: referral — "invite a friend, plant a tree for both".
                    } label: {
                        Label("Invite a friend — a tree for both of you", systemImage: "gift.fill")
                    }
                }

                Section("Notifications") {
                    Toggle("Care reminders", isOn: $remindersOn)
                        .onChange(of: remindersOn) { _, on in
                            app.notifications.remindersEnabled = on
                            Task {
                                if on { await app.notifications.requestAuthorizationIfNeeded() }
                                await app.notifications.reschedule(for: app.garden.plants)
                            }
                        }
                }

                Section("About") {
                    if let url = URL(string: "https://verdancy.app/privacy") {
                        Link("Privacy Policy", destination: url)
                    }
                    if let url = URL(string: "https://verdancy.app/terms") {
                        Link("Terms of Service", destination: url)
                    }
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

#Preview {
    SettingsView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
