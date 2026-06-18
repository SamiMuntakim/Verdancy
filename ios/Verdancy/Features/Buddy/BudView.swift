import SwiftUI

/// The per-plant Plant Bud (iOS-PRD §9). Two states: a **dormant closed bud** before
/// subscribing (the locked teaser) and the **bloomed buddy** after. The bloom
/// animation + the bundled starter sprite set land in Phase 4; this renders symbolic
/// placeholders (swap in the real pixel sprites then).
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
                    image.resizable().interpolation(.none).scaledToFit().padding(size * 0.14)
                } placeholder: {
                    bloomedFallback
                }
            } else {
                bloomedFallback
            }
        } else {
            // Dormant, "forming," not yet open.
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(Theme.Color.leafDeep.opacity(0.45))
        }
    }

    private var bloomedFallback: some View {
        Image(systemName: "camera.macro")
            .font(.system(size: size * 0.5))
            .foregroundStyle(Theme.Color.leaf)
    }
}

#Preview {
    HStack(spacing: 24) {
        BudView(plant: .sample, isSubscribed: false, size: 64)
        BudView(plant: .sample, isSubscribed: true, size: 64)
    }
    .padding()
}
