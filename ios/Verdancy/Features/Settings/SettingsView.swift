import SwiftUI

/// Settings (iOS-PRD §3.4).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showPaywall = false
    @State private var remindersOn = NotificationService.shared.remindersEnabled
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String?

    private var totalTrees: Int {
        (app.isSubscribed ? 10 : 0) + app.garden.trees.treesPledged
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Plan", value: app.isSubscribed ? "Subscriber" : "Free")
                    Button("Sign out") { Task { await app.signOut() } }
                    Button("Delete account", role: .destructive) { showDeleteConfirm = true }
                        .disabled(deleting)
                    if let deleteError {
                        Text(deleteError).font(.footnote).foregroundStyle(Theme.Color.danger)
                    }
                }

                Section("Subscription") {
                    LabeledContent("Status", value: app.isSubscribed ? "Active" : "Not subscribed")
                    if !app.isSubscribed {
                        Button("See plans") { showPaywall = true }
                    }
                    Button("Restore purchases") { Task { await app.entitlement.restore() } }
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        Link("Manage subscription", destination: url)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: Binding(
                        get: { app.appearance },
                        set: { app.setAppearance($0) }
                    )) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
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
                    ShareLink(item: Invite.url, message: Text(Invite.message)) {
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
            .confirmationDialog(
                "Delete your account?",
                isPresented: $showDeleteConfirm, titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task {
                        deleting = true
                        deleteError = nil
                        do {
                            try await app.deleteAccount()
                        } catch {
                            deleteError = "Couldn't delete your account. Please try again."
                        }
                        deleting = false
                    }
                }
            } message: {
                Text("This permanently removes your account, plants, photos, and data. This can't be undone.")
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

#Preview {
    SettingsView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
