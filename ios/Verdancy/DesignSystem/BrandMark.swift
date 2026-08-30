import SwiftUI

/// The Verdancy app mark — the leaf logo rendered as a rounded app-icon chip, so the
/// opaque square asset reads as an intentional brand mark on any background (light or
/// dark). One treatment everywhere the mark appears: launch, onboarding, settings.
struct BrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("VerdancyLogoInverted")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            // Apple's icon superellipse ≈ 0.2237 × side, drawn as a continuous curve
            // so the chip matches the real home-screen icon's corner.
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: Theme.Color.leafDeep.opacity(0.22), radius: size * 0.14, y: size * 0.06)
    }
}

/// Horizontal brand lockup: the mark beside the "Verdancy" wordmark (SF Pro, no
/// novelty typeface — the personality is the mark). Used as a quiet masthead.
struct BrandLockup: View {
    var markSize: CGFloat = 28

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            BrandMark(size: markSize)
            Text("Verdancy")
                .font(.headline.weight(.bold))
                .kerning(0.2)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verdancy")
    }
}

#Preview {
    VStack(spacing: 32) {
        BrandMark(size: 92)
        BrandLockup()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Color.background)
}
