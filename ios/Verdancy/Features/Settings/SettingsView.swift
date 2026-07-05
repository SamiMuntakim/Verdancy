import SwiftUI

/// Settings (iOS-PRD §3.4).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showPaywall = false
    @State private var remindersOn = NotificationService.shared.remindersEnabled
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var inviteCodeInput = ""
    @State private var redeeming = false
    @State private var redeemMessage: String?
    @State private var redeemSucceeded = false

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
                        Label(milestoneLabel(milestone), systemImage: "tree.fill")
                    }
                    Link("View the public tree counter", destination: AppConfig.treeCounterURL)
                }

                Section("Grow the forest") {
                    ShareLink(
                        item: Invite.url,
                        message: Text(Invite.message(code: app.referralCode))
                    ) {
                        Label("Invite a friend — a tree for both of you", systemImage: "gift.fill")
                    }
                    if let code = app.referralCode {
                        LabeledContent("Your invite code", value: code)
                    }
                    HStack {
                        TextField("Have a code? Enter it", text: $inviteCodeInput)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Apply") { Task { await redeemInvite() } }
                            .disabled(inviteCodeInput.trimmingCharacters(in: .whitespaces).isEmpty
                                      || redeeming)
                    }
                    if let redeemMessage {
                        Text(redeemMessage).font(.footnote)
                            .foregroundStyle(redeemSucceeded ? Theme.Color.leaf : Theme.Color.danger)
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
                    Link("Privacy Policy", destination: AppConfig.privacyURL)
                    Link("Terms of Service", destination: AppConfig.termsURL)
                    Link("Support", destination: AppConfig.supportURL)
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

    private func milestoneLabel(_ id: String) -> String {
        if id.hasPrefix("referral_") { return id == "referral_joined" ? "Joined Via Invite" : "Friend Invited" }
        return id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func redeemInvite() async {
        redeeming = true
        redeemMessage = nil
        let code = inviteCodeInput.trimmingCharacters(in: .whitespaces).uppercased()
        do {
            if !AppConfig.useMockAuth { try await app.api.redeemInvite(code: code) }
            redeemSucceeded = true
            redeemMessage = "Invite applied — a tree gets planted for you both when you subscribe. 🌳"
            inviteCodeInput = ""
            Haptics.success()
        } catch {
            redeemSucceeded = false
            redeemMessage = (error as? APIError)?.userMessage ?? "That code didn't work."
        }
        redeeming = false
    }
}

#Preview {
    SettingsView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
