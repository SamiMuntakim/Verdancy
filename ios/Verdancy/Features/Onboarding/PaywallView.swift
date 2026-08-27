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

    // Prices come from StoreKit via RevenueCat, never hardcoded (Guideline 3.1.2).
    private var annualPrice: EntitlementService.PlanPrice? { app.entitlement.price(for: .annual) }
    private var monthlyPrice: EntitlementService.PlanPrice? { app.entitlement.price(for: .monthly) }
    private var priceUnavailable: Bool { (plan == .annual ? annualPrice : monthlyPrice) == nil }

    private func annualSubtitle(_ price: EntitlementService.PlanPrice?) -> String {
        if let perMonth = price?.perMonth {
            return "7-day free trial · just \(perMonth)/mo, billed yearly"
        }
        return "7-day free trial · billed yearly"
    }

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
                        Text("Free gives you \(AppConfig.freeDailyScanCount) plant IDs a day. Premium unlocks the whole thing.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .padding(.horizontal, Theme.Space.l)
                    }
                    .padding(.top, Theme.Space.l)

                    PlanComparison()

                    SocialProofCard()

                    VStack(spacing: Theme.Space.m) {
                        PlanRow(title: "Annual", price: annualPrice?.total ?? "—",
                                subtitle: annualSubtitle(annualPrice),
                                badge: annualPrice?.savingsPercent.map { "SAVE \($0)%" },
                                selected: plan == .annual) { plan = .annual }
                        PlanRow(title: "Monthly", price: monthlyPrice?.total ?? "—",
                                subtitle: "Flexible, month to month",
                                badge: nil,
                                selected: plan == .monthly) { plan = .monthly }
                    }

                    Button {
                        Task { await subscribe() }
                    } label: {
                        Text(priceUnavailable ? "Loading plans…"
                             : isWorking ? "Starting…"
                             : plan == .annual ? "Start my 7-day free trial" : "Subscribe monthly")
                    }
                    .buttonStyle(.primary)
                    .disabled(isWorking || priceUnavailable)

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

/// The conversion centerpiece (iOS-PRD §7/§8): a stark Free-vs-Premium table. Free
/// is honestly bare — 2 identifications a day and nothing else — so the premium
/// column, which carries every real feature *including the real trees*, does the
/// selling. Numbers come from `AppConfig` so client copy tracks the server gate.
struct PlanComparison: View {
    /// A capability row. `free` is the free-tier value (nil → not included, shown as
    /// a muted dash); premium is always included (`premiumValue` nil → a check).
    private struct Row {
        let icon: String
        let label: String
        let free: String?
        let premiumValue: String?
    }

    private var rows: [Row] {
        [
            Row(icon: "camera.viewfinder", label: "Plant identification",
                free: "\(AppConfig.freeDailyScanCount)/day", premiumValue: "Unlimited"),
            Row(icon: "list.bullet.clipboard.fill", label: "Personalized care plans",
                free: nil, premiumValue: nil),
            Row(icon: "bell.badge.fill", label: "Watering & care reminders",
                free: nil, premiumValue: nil),
            Row(icon: "stethoscope", label: "Diagnose sick plants",
                free: nil, premiumValue: nil),
            Row(icon: "sparkles", label: "Blooming plant buddies",
                free: nil, premiumValue: nil),
            Row(icon: "flame.fill", label: "Care streaks & stats",
                free: nil, premiumValue: nil),
            Row(icon: "tree.fill", label: "Real trees planted",
                free: nil, premiumValue: "10 +"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Column headers.
            HStack(spacing: Theme.Space.m) {
                Text("Everything you get")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Free")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 62)
                Text("Premium")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.Color.leaf)
                    .frame(width: 72)
            }
            .padding(.bottom, Theme.Space.s)

            ForEach(rows.indices, id: \.self) { i in
                if i > 0 { Divider().overlay(Theme.Color.separator) }
                rowView(rows[i])
            }
        }
        .padding(Theme.Space.l)
        .card()
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: row.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Color.leaf)
                    .frame(width: 24, height: 24)
                    .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                Text(row.label).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cell(freeText: row.free, included: row.free != nil, emphasized: false)
                .frame(width: 62)
            cell(freeText: row.premiumValue, included: true, emphasized: true)
                .frame(width: 72)
        }
        .padding(.vertical, Theme.Space.m)
    }

    /// A value cell: shows the text if present, a check when included without a
    /// value, or a muted dash when the tier doesn't include it.
    @ViewBuilder
    private func cell(freeText: String?, included: Bool, emphasized: Bool) -> some View {
        if let freeText {
            Text(freeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(emphasized ? Theme.Color.leaf : Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
        } else if included {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(emphasized ? Theme.Color.leaf : Theme.Color.textPrimary)
        } else {
            Image(systemName: "minus")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.Color.separator)
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
