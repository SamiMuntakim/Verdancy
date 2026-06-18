import SwiftUI

/// Hard paywall (iOS-PRD §7/§8). Leads with the dual value — keep plants alive +
/// plant 10 real trees — annual as the hero, 7-day trial. RevenueCat offerings +
/// the bloom reveal are wired in Phase 4; this is the structured shell.
struct PaywallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var plan: Plan = .annual
    @State private var isWorking = false

    enum Plan { case annual, monthly }

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
                                subtitle: "Best value · 7-day free trial",
                                selected: plan == .annual) { plan = .annual }
                        PlanRow(title: "Monthly", price: "$7.99 / mo",
                                subtitle: "", selected: plan == .monthly) { plan = .monthly }
                    }

                    Button {
                        Task { await subscribe() }
                    } label: {
                        Text(isWorking ? "Starting…" : "Start 7-day free trial")
                            .frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.Color.leaf)
                    .disabled(isWorking)

                    Button("Restore Purchases") {}.font(.footnote)
                    Text("Cancel anytime. We stagger your 10 trees across the first year.")
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
        // Phase 4: drive via RevenueCat (trial start → bloom reveal). For now flip the
        // local entitlement so the trees/buddy demo works; the server is the authority.
        isWorking = true
        try? await Task.sleep(for: .milliseconds(500))
        app.isSubscribed = true
        Haptics.celebrate()
        isWorking = false
        dismiss()
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
