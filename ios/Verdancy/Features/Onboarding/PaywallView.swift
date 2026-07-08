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
                    VStack(spacing: Theme.Space.m) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(
                                Theme.leafGradient,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                        Text("Keep your plants alive —\nand plant 10 real trees.")
                            .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    }
                    .padding(.top, Theme.Space.l)

                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        FeatureRow(icon: "camera.viewfinder", text: "Unlimited plant identification")
                        FeatureRow(icon: "stethoscope", text: "Instant diagnoses for ailing plants")
                        FeatureRow(icon: "bell.badge.fill", text: "Care reminders and streaks")
                        FeatureRow(icon: "sparkles", text: "Your buddies bloom for every plant")
                        FeatureRow(icon: "tree.fill", text: "10 real trees planted — plus more as you grow")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.l)
                    .card()

                    SocialProofCard()

                    VStack(spacing: Theme.Space.m) {
                        PlanRow(title: "Annual", price: "$39.99 / yr",
                                subtitle: "7-day free trial · just $3.33/mo, billed yearly",
                                badge: "SAVE 58%",
                                selected: plan == .annual) { plan = .annual }
                        PlanRow(title: "Monthly", price: "$7.99 / mo",
                                subtitle: "Flexible, month to month",
                                badge: nil,
                                selected: plan == .monthly) { plan = .monthly }
                    }

                    Button {
                        Task { await subscribe() }
                    } label: {
                        Text(isWorking ? "Starting…"
                             : plan == .annual ? "Start my 7-day free trial" : "Subscribe monthly")
                    }
                    .buttonStyle(.primary)
                    .disabled(isWorking)

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Theme.Color.danger)
                    }
                    Button("Restore Purchases") {
                        Task { await app.entitlement.restore(); if app.isSubscribed { dismiss() } }
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
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
            .onAppear { Analytics.log("paywall_viewed") }
        }
    }

    private func subscribe() async {
        isWorking = true
        error = nil
        Analytics.log("trial_start_tapped", ["plan": plan == .annual ? "annual" : "monthly"])
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

/// Honest social proof (iOS-PRD §8/§10): named partner + a public, verifiable tree
/// counter. The App Store rating row stays off until real reviews exist.
struct SocialProofCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if AppConfig.showPaywallRating {
                HStack(spacing: Theme.Space.s) {
                    ForEach(0..<5, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.Color.warning)
                    }
                    Text("Loved by plant parents")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Color.leaf)
                    .frame(width: 28, height: 28)
                    .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Real trees, publicly counted")
                        .font(.subheadline.weight(.semibold))
                    Text("Planted with \(AppConfig.plantingPartner) — every tree shows on our live public counter.")
                        .font(.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            Link(destination: AppConfig.treeCounterURL) {
                HStack(spacing: Theme.Space.xs) {
                    Text("See the live tree counter")
                    Image(systemName: "arrow.up.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 28, height: 28)
                .background(Theme.Color.leaf.opacity(0.12), in: Circle())
            Text(text).font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.Color.leaf)
        }
    }
}

struct PlanRow: View {
    let title: String
    let price: String
    let subtitle: String
    let badge: String?
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.s) {
                        Text(title).font(.headline).foregroundStyle(Theme.Color.textPrimary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.Color.terracotta.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.Color.terracotta)
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.Color.textSecondary)
                    }
                }
                Spacer()
                Text(price).fontWeight(.semibold).foregroundStyle(Theme.Color.textPrimary)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.Color.leaf : Theme.Color.separator)
            }
            .padding(Theme.Space.l)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(selected ? Theme.Color.leaf.opacity(0.08) : Theme.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(selected ? Theme.Color.leaf : Theme.Color.separator,
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

#Preview {
    PaywallView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
