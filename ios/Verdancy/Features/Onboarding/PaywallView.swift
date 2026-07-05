import SwiftUI

/// Hard paywall (iOS-PRD §7/§8). Leads with the dual value — keep plants alive +
/// plant 10 real trees — annual as the hero, 7-day trial. RevenueCat offerings +
/// the bloom reveal are wired in Phase 4; this is the structured shell.
struct PaywallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var plan: EntitlementService.Plan = .annual
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.l) {
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: "leaf.circle.fill")
                            .font(.system(size: 64)).foregroundStyle(Theme.Color.leaf)
                        Text("Keep your plants alive —\nand plant 10 real trees.")
                            .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        Text("Unlimited identify, plant diagnoses, care reminders, streaks, and your blooming buddies.")
                            .font(.subheadline).multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .padding(.top, Theme.Space.l)

                    VStack(spacing: Theme.Space.m) {
                        PlanRow(title: "Annual", price: "$39.99 / yr",
                                subtitle: "7-day free trial · just $3.33/mo, billed yearly",
                                selected: plan == .annual) { plan = .annual }
                        PlanRow(title: "Monthly", price: "$7.99 / mo",
                                subtitle: "Flexible, month to month",
                                selected: plan == .monthly) { plan = .monthly }
                    }

                    Button {
                        Task { await subscribe() }
                    } label: {
                        Text(isWorking ? "Starting…"
                             : plan == .annual ? "Start my 7-day free trial" : "Subscribe monthly")
                            .frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.Color.leaf)
                    .disabled(isWorking)

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Theme.Color.danger)
                    }
                    Button("Restore Purchases") {
                        Task { await app.entitlement.restore(); if app.isSubscribed { dismiss() } }
                    }
                    .font(.footnote)
                    Text("No charge until your free trial ends — cancel in two taps. Your 10 trees are planted across your first year.")
                        .font(.caption2).multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .padding(Theme.Space.l)
            }
            .background(Theme.Color.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func subscribe() async {
        isWorking = true
        error = nil
        do {
            // Starts the trial via RevenueCat (or mock), then the bloom reveal fires
            // from RootView via app.pendingBloom. The server stays the access authority.
            try await app.startTrial(plan)
            dismiss()
        } catch {
            self.error = "Couldn't start the trial. Please try again."
        }
        isWorking = false
    }
}

struct PlanRow: View {
    let title: String
    let price: String
    let subtitle: String
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Theme.Color.textPrimary)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.Color.textSecondary)
                    }
                }
                Spacer()
                Text(price).fontWeight(.semibold).foregroundStyle(Theme.Color.textPrimary)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Color.leaf : Theme.Color.separator)
            }
            .padding(Theme.Space.m)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .stroke(selected ? Theme.Color.leaf : Theme.Color.separator, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    PaywallView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
