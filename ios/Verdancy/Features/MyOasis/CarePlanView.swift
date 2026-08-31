import SwiftUI

/// The personalized care plan, rendered as three cards: Water, Light, Nutrients
/// (iOS-PRD §3.3). The copy is generated to the plant's real environment.
///
/// Two modes:
/// - Plain (`plan` only): the three guidance cards, used right after generation
///   in PersonalizeCareView, where logging care makes no sense yet.
/// - Interactive (`plant` + `onLog`): each scheduled card also answers "when is
///   it next due?" and carries its own completion tap, so plan, status, and action
///   live together instead of being restated in a separate "Log care" list.
struct CarePlanView: View {
    let plan: CarePlan
    var plant: Plant?
    var onLog: ((CareType) async -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            CarePlanSection(
                icon: "drop.fill", tone: .water, title: "Water",
                headline: "\(plan.water.amount) · every \(plan.water.cadenceDays) days",
                detail: WaterPlan.dedupe(plan.water.instruction,
                                         amount: plan.water.amount,
                                         cadenceDays: plan.water.cadenceDays),
                task: task(for: .water), careType: .water, onLog: onLog)
            CarePlanSection(
                icon: "sun.max.fill", tone: .sun, title: "Light",
                headline: plan.light.summary, detail: plan.light.instruction)
            CarePlanSection(
                icon: "leaf.fill", tone: .leaf, title: "Nutrients",
                headline: nutrientsHeadline, detail: plan.nutrients.instruction,
                task: plan.nutrients.fertilizeCadenceDays != nil ? task(for: .fertilize) : nil,
                careType: .fertilize, onLog: onLog)
            if let prune = task(for: .prune), let cadence = prune.cadenceDays {
                CarePlanSection(
                    icon: CareType.prune.systemImage, tone: .ember,
                    title: "Prune", headline: "Every \(cadence) days", detail: nil,
                    task: prune, careType: .prune, onLog: onLog)
            }
        }
    }

    private var nutrientsHeadline: String {
        if let days = plan.nutrients.fertilizeCadenceDays { return "Feed every \(days) days" }
        return "Repotting keeps it fed"
    }

    private func task(for type: CareType) -> CareTask? {
        plant?.care.task(for: type)
    }
}

/// One domain of the plan as a color-coded card. The tone (blue / gold / green)
/// carries the domain, so the three cards are distinguishable before a word is
/// read; status and the completion tap ride the title row, leaving the sentence
/// that actually matters as the largest thing on the card.
private struct CarePlanSection: View {
    let icon: String
    let tone: Theme.Tone
    let title: String
    let headline: String
    let detail: String?
    var task: CareTask?
    var careType: CareType = .water
    var onLog: ((CareType) async -> Void)?

    @State private var isLogging = false

    /// Days until next due: negative = overdue, 0 = today. `nil` hides the row
    /// (no cadence, never logged, or the plain non-interactive mode).
    private var daysUntilDue: Int? {
        guard onLog != nil, let due = task?.nextDue() else { return nil }
        let cal = Calendar.current
        return cal.dateComponents(
            [.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: due)).day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                GlyphTile(systemImage: icon, tone: tone, size: 40)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(tone.tint)
                Spacer(minLength: Theme.Space.xs)
                if let days = daysUntilDue {
                    DueStatusPill(days: days)
                    if let onLog {
                        CompleteCareButton(tone: tone, isBusy: isLogging) {
                            isLogging = true
                            Task {
                                await onLog(careType)
                                isLogging = false
                            }
                        }
                        .accessibilityLabel("Mark \(title.lowercased()) done")
                    }
                }
            }
            Text(headline)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card(tone: tone)
    }
}

extension WaterPlan {
    /// The generated instruction usually opens by restating the headline
    /// ("Water 1.5 cups every 10 days, letting the top inch dry first"). When it
    /// does — an exact prefix match only — show just the useful remainder, so the
    /// card doesn't say the same thing twice. Presentation-only: any wording the
    /// model chose that doesn't match passes through untouched.
    static func dedupe(_ instruction: String, amount: String, cadenceDays: Int) -> String {
        let prefix = "water \(amount.lowercased()) every \(cadenceDays) days"
        guard instruction.lowercased().hasPrefix(prefix) else { return instruction }
        var rest = String(instruction.dropFirst(prefix.count))
        while let first = rest.first, first == " " || first == "," || first == "." {
            rest.removeFirst()
        }
        guard rest.count >= 10 else { return instruction }
        // "…, letting the top inch dry first" → "Let the top inch dry first."
        // Only the handful of gerunds this sentence shape actually produces; any
        // other opening word passes through with just its first letter uppercased.
        let gerunds = ["letting": "Let", "allowing": "Allow", "keeping": "Keep",
                       "making": "Make", "ensuring": "Ensure", "giving": "Give"]
        let firstWord = rest.prefix { $0.isLetter }.lowercased()
        if let imperative = gerunds[firstWord] {
            rest = imperative + rest.dropFirst(firstWord.count)
        } else {
            rest = rest.prefix(1).uppercased() + rest.dropFirst()
        }
        if let last = rest.last, !".!?".contains(last) { rest += "." }
        return rest
    }
}

#Preview("Plain") {
    ScrollView {
        CarePlanView(plan: .sample).padding()
    }
    .background(Theme.Color.background)
}

#Preview("Interactive") {
    ScrollView {
        CarePlanView(plan: .sample, plant: .sample, onLog: { _ in }).padding()
    }
    .background(Theme.Color.background)
}
