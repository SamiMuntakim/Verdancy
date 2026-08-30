import SwiftUI

/// The personalized care plan, rendered as three cards: Water, Light, Nutrients
/// (iOS-PRD §3.3). The copy is generated to the plant's real environment.
///
/// Two modes:
/// - Plain (`plan` only): the three guidance cards, used right after generation
///   in PersonalizeCareView, where logging care makes no sense yet.
/// - Interactive (`plant` + `onLog`): each scheduled card also answers "when is
///   it next due?" and carries its own Done button, so plan, status, and action
///   live together instead of being restated in a separate "Log care" list.
struct CarePlanView: View {
    let plan: CarePlan
    var plant: Plant?
    var onLog: ((CareType) async -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            CarePlanSection(
                icon: "drop.fill", tint: Theme.Color.water, title: "Water",
                headline: "\(plan.water.amount) · every \(plan.water.cadenceDays) days",
                detail: WaterPlan.dedupe(plan.water.instruction,
                                         amount: plan.water.amount,
                                         cadenceDays: plan.water.cadenceDays),
                task: task(for: .water), careType: .water, onLog: onLog)
            CarePlanSection(
                icon: "sun.max.fill", tint: Theme.Color.warning, title: "Light",
                headline: plan.light.summary, detail: plan.light.instruction)
            CarePlanSection(
                icon: "leaf.fill", tint: Theme.Color.leaf, title: "Nutrients",
                headline: nutrientsHeadline, detail: plan.nutrients.instruction,
                task: plan.nutrients.fertilizeCadenceDays != nil ? task(for: .fertilize) : nil,
                careType: .fertilize, onLog: onLog)
            if let prune = task(for: .prune), let cadence = prune.cadenceDays {
                CarePlanSection(
                    icon: CareType.prune.systemImage, tint: Theme.Color.terracotta,
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

private struct CarePlanSection: View {
    let icon: String
    let tint: Color
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
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: Circle())
                Text(title).font(.headline)
                Spacer()
            }
            Text(headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let days = daysUntilDue, let onLog {
                HStack {
                    duePill(days: days)
                    Spacer()
                    Button(isLogging ? "Saving…" : "Done") {
                        isLogging = true
                        Task {
                            await onLog(careType)
                            isLogging = false
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Color.leaf)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                    .background(Theme.Color.leaf.opacity(0.12), in: Capsule())
                    .disabled(isLogging)
                    .accessibilityLabel("Mark \(title.lowercased()) done")
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
    }

    @ViewBuilder
    private func duePill(days: Int) -> some View {
        let (text, color): (String, Color) =
            days < 0 ? ("\(-days)d late", Theme.Color.warning)
            : days == 0 ? ("Due today", Theme.Color.leaf)
            : ("Due in \(days)d", Theme.Color.textSecondary)
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
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
