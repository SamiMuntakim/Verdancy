import SwiftUI

/// The per-plant Plant Bud (iOS-PRD §9). Two states: a **dormant closed bud** before
/// subscribing (the locked teaser) and the **bloomed buddy** after. Uses the bundled
/// pixel sprites (starter set + generic fallback); a rare species with a generated
/// remote sprite (backend Appendix A) is preferred when available.
///
/// Framing rule (§8): always "look what's growing for you" — never punitive.
struct BudView: View {
    let plant: Plant
    let isSubscribed: Bool
    var size: CGFloat = 44

    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.Color.leaf.opacity(0.15))
            content
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        if isSubscribed {
            Group {
                if let urlString = plant.buddy?.spriteUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().interpolation(.none).scaledToFit()
                    } placeholder: {
                        bundledBloom
                    }
                    .padding(size * 0.08)
                } else {
                    bundledBloom.padding(size * 0.08)
                }
            }
            // Mood (iOS-PRD §9): a gentle droop when care is a day past due —
            // "I could use you", never shamed or harmed.
            .rotationEffect(.degrees(isThirsty ? 5 : 0))
            .saturation(isThirsty ? 0.72 : 1)
            .overlay(alignment: .bottomTrailing) {
                if isThirsty {
                    Image(systemName: "drop.fill")
                        .font(.system(size: size * 0.18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(size * 0.07)
                        .background(Circle().fill(.blue))
                }
            }
        } else {
            // Dormant teaser (iOS-PRD §8.3): a slow breath invites the tap that
            // opens the paywall — "something's forming."
            sprite(BudSprites.dormant)
                .padding(size * 0.08)
                .opacity(0.85)
                .scaleEffect(breathing ? 1.06 : 0.96)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                }
        }
    }

    /// A full day past any due date — the grace period keeps the buddy from
    /// drooping the moment a task ticks over.
    private var isThirsty: Bool {
        let now = Date()
        return CareType.allCases.contains { type in
            guard let due = plant.care.task(for: type).nextDue(now: now) else { return false }
            return now.timeIntervalSince(due) > 86_400
        }
    }

    private var accessibilityText: String {
        if !isSubscribed { return "Dormant bud — subscribe to bloom" }
        return isThirsty ? "Plant buddy — care is due" : "Plant buddy"
    }

    private var bundledBloom: some View {
        sprite(BudSprites.bloomAsset(for: plant.species))
    }

    private func sprite(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.none) // crisp pixel art
            .scaledToFit()
    }
}

#Preview {
    HStack(spacing: 24) {
        BudView(plant: .sample, isSubscribed: false, size: 64)
        BudView(plant: .sample, isSubscribed: true, size: 64)
        BudView(plant: .sampleSnake, isSubscribed: true, size: 64)
        BudView(plant: .sampleUnknown, isSubscribed: true, size: 64)
    }
    .padding()
}
