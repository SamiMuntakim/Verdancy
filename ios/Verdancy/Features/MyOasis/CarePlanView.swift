import SwiftUI

/// The personalized care plan, rendered as three cards: Water, Light, Nutrients
/// (iOS-PRD §3.3). The copy is generated to the plant's real environment.
struct CarePlanView: View {
    let plan: CarePlan

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            CarePlanSection(
                icon: "drop.fill", tint: .blue, title: "Water",
                headline: "\(plan.water.amount) every \(plan.water.cadenceDays) days",
                detail: plan.water.instruction)
            CarePlanSection(
                icon: "sun.max.fill", tint: Theme.Color.warning, title: "Light",
                headline: plan.light.summary, detail: plan.light.instruction)
            CarePlanSection(
                icon: "leaf.fill", tint: Theme.Color.leaf, title: "Nutrients",
                headline: nutrientsHeadline, detail: plan.nutrients.instruction)
        }
    }

    private var nutrientsHeadline: String {
        if let days = plan.nutrients.fertilizeCadenceDays { return "Feed every \(days) days" }
        return "Repotting keeps it fed"
    }
}

private struct CarePlanSection: View {
    let icon: String
    let tint: Color
    let title: String
    let headline: String
    let detail: String

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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
    }
}

#Preview {
    ScrollView {
        CarePlanView(plan: .sample).padding()
    }
    .background(Theme.Color.background)
}
