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

    var body: some View {
        ZStack {
            Circle().fill(Theme.Color.leaf.opacity(0.15))
            content
        }
        .frame(width: size, height: size)
        .accessibilityLabel(isSubscribed ? "Plant buddy" : "Dormant bud — subscribe to bloom")
    }

    @ViewBuilder
    private var content: some View {
        if isSubscribed {
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
        } else {
            sprite(BudSprites.dormant)
                .padding(size * 0.08)
                .opacity(0.85)
        }
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
