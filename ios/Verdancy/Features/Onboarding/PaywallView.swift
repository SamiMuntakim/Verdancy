import SwiftUI

/// Hard paywall (iOS-PRD §7/§8). Leads with the dual value — keep plants alive +
/// plant 10 real trees — annual as the hero, 7-day trial. The centerpiece is the
/// trial timeline: saying out loud when the charge lands (and that we remind you
/// first) is what defuses trial anxiety, the #1 subscribe objection. Prices come
/// from StoreKit via RevenueCat, never hardcoded (Guideline 3.1.2).
struct PaywallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var plan: EntitlementService.Plan = .annual
    @State private var isWorking = false
    @State private var error: String?

    private var annualPrice: EntitlementService.PlanPrice? { app.entitlement.price(for: .annual) }
    private var monthlyPrice: EntitlementService.PlanPrice? { app.entitlement.price(for: .monthly) }
    private var priceUnavailable: Bool { (plan == .annual ? annualPrice : monthlyPrice) == nil }

    /// A plan whose product never came back from StoreKit can't be bought, so it is
    /// hidden rather than shown as a row that says "Loading plans…" forever. Before
    /// the offering lands, both rows show so the layout doesn't jump.
    private func planAvailable(_ candidate: EntitlementService.Plan) -> Bool {
        guard app.entitlement.offeringLoaded else { return true }
        return (candidate == .annual ? annualPrice : monthlyPrice) != nil
    }

    private func annualSubtitle(_ price: EntitlementService.PlanPrice?) -> String {
        if let perMonth = price?.perMonth, let total = price?.total {
            return "Then \(total)/yr, about \(perMonth)/mo · funds 10 trees"
        }
        return "7-day free trial · billed yearly · funds 10 trees"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.l) {
                    hero
                    TrialTimeline(plan: plan)
                    planRows
                    dueToday
                    subscribeButton
                    reassurance
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Theme.Color.danger)
                    }
                    footerLinks
                    legalLinks
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

    private var hero: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack {
                Circle()
                    .fill(Theme.Color.leaf.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(BudSprites.generic)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 72, height: 72)
            }
            Text("Keep every plant alive.\nPlant 10 real trees.")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Space.s)
    }

    private var planRows: some View {
        VStack(spacing: Theme.Space.m) {
            if planAvailable(.annual) {
                PlanRow(title: "Annual · 7 days free",
                        price: annualPrice?.total ?? "-",
                        subtitle: annualSubtitle(annualPrice),
                        badge: annualPrice?.savingsPercent.map { "BEST VALUE · SAVE \($0)%" },
                        selected: plan == .annual) { plan = .annual }
            }
            if planAvailable(.monthly) {
                PlanRow(title: "Monthly",
                        price: monthlyPrice?.total ?? "-",
                        subtitle: "Flexible · funds 1 tree every month",
                        badge: nil,
                        selected: plan == .monthly) { plan = .monthly }
            }
        }
        // Never leave the user selected on a plan that isn't purchasable.
        .onChange(of: app.entitlement.offeringLoaded) { _, _ in
            if !planAvailable(plan) {
                plan = planAvailable(.annual) ? .annual : .monthly
            }
        }
    }

    /// The article's highest-confidence lever: say the money isn't moving *today*,
    /// directly above the button where the thumb hesitates. Annual is a true "$0.00
    /// today" (7-day trial); monthly bills now, so it states the real charge honestly
    /// rather than a misleading "no payment."
    private var dueToday: some View {
        VStack(spacing: 2) {
            if plan == .annual {
                Text("No payment due today")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .monospacedDigit()
                if let total = annualPrice?.total {
                    Text("Then \(total)/yr on Day 7 · cancel anytime before")
                        .font(.footnote)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .monospacedDigit()
                }
            } else {
                if let total = monthlyPrice?.total {
                    Text("\(total) billed today")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .monospacedDigit()
                }
                Text("Renews monthly · cancel anytime")
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var subscribeButton: some View {
        Button {
            Task { await subscribe() }
        } label: {
            Text(priceUnavailable ? "Loading plans…"
                 : isWorking ? "Starting…"
                 : plan == .annual ? "Start my free week" : "Subscribe monthly")
        }
        .buttonStyle(.primary)
        .disabled(isWorking || priceUnavailable)
    }

    /// Money framing lives in `dueToday` above the button; this line under the CTA
    /// carries the cancel-ease reassurance, the other half of trial anxiety.
    private var reassurance: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
            Text("Cancel anytime in two taps")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private var footerLinks: some View {
        HStack(spacing: Theme.Space.l) {
            // Honest social proof (iOS-PRD §10): a public, verifiable tree counter.
            Link(destination: AppConfig.treeCounterURL) {
                HStack(spacing: Theme.Space.xs) {
                    Text("See the live tree counter")
                    Image(systemName: "arrow.up.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
            }
            Rectangle()
                .fill(Theme.Color.separator)
                .frame(width: 1, height: 12)
            Button("Restore Purchases") {
                Task { await app.entitlement.restore(); if app.isSubscribed { dismiss() } }
            }
            .font(.caption)
            .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    /// Apple Guideline 3.1.2 requires functional Terms of Use and Privacy Policy
    /// links on the subscription purchase screen itself — reviewers reject without
    /// them. Same destinations as Settings.
    private var legalLinks: some View {
        HStack(spacing: Theme.Space.l) {
            Link("Terms of Service", destination: AppConfig.termsURL)
            Rectangle()
                .fill(Theme.Color.separator)
                .frame(width: 1, height: 12)
            Link("Privacy Policy", destination: AppConfig.privacyURL)
        }
        .font(.caption)
        .foregroundStyle(Theme.Color.textSecondary)
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

/// What actually happens, and when — including the moment money moves and the
/// moment trees are planted (both on Day 7; trees follow the payment, never the
/// signup, mirroring the webhook's `isPaidPeriod` rule). The monthly variant has
/// no trial, so its steps describe the immediate charge and the monthly tree.
struct TrialTimeline: View {
    let plan: EntitlementService.Plan

    private struct Step {
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    private var steps: [Step] {
        switch plan {
        case .annual:
            return [
                Step(icon: "lock.open.fill", tint: Theme.Color.leaf,
                     title: "Today, everything unlocks",
                     detail: "Unlimited IDs, tailored care plans, plant diagnosis, and your buddy blooms."),
                Step(icon: "bell.badge.fill", tint: Theme.Color.warning,
                     title: "Day 5, we remind you",
                     detail: "A heads-up before your trial ends. Cancel in two taps, keep the free tier."),
                Step(icon: "tree.fill", tint: Theme.Color.leafDeep,
                     title: "Day 7, your 10 trees go in the ground",
                     detail: "Your first payment funds 10 real trees through \(AppConfig.plantingPartner), certificates and all."),
            ]
        case .monthly:
            return [
                Step(icon: "lock.open.fill", tint: Theme.Color.leaf,
                     title: "Today, everything unlocks",
                     detail: "Unlimited IDs, tailored care plans, plant diagnosis, and your buddy blooms."),
                Step(icon: "tree.fill", tint: Theme.Color.leafDeep,
                     title: "Every month, a real tree is planted",
                     detail: "Each payment funds one tree through \(AppConfig.plantingPartner), certificate included."),
                Step(icon: "hand.wave.fill", tint: Theme.Color.terracotta,
                     title: "Cancel anytime, in two taps",
                     detail: "Your forest and its certificates stay yours."),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            let steps = steps
            ForEach(steps.indices, id: \.self) { i in
                stepView(steps[i], isLast: i == steps.count - 1)
            }
        }
        .padding(Theme.Space.l)
        .card()
        .animation(.easeOut(duration: 0.2), value: plan == .annual)
    }

    private func stepView(_ step: Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(spacing: 3) {
                Image(systemName: step.icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(step.tint)
                    .frame(width: 30, height: 30)
                    .background(step.tint.opacity(0.14), in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(Theme.Color.separator)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.subheadline.weight(.bold))
                Text(step.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : Theme.Space.m)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    Text(title).font(.headline).foregroundStyle(Theme.Color.textPrimary)
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
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.Color.terracotta, in: Capsule())
                        .offset(x: Theme.Space.m, y: -9)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

#Preview {
    PaywallView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
