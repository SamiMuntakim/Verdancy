import SwiftUI
import UIKit

/// Premium, calm, plant-forward palette (iOS-PRD §14): green-forward with a warm
/// terracotta accent, full dark mode. Colors are defined in code (dynamic
/// light/dark) so there's no asset-catalog dependency.
enum Theme {
    enum Color {
        static let leaf = dynamicColor(light: 0x4C9153, dark: 0x6FB477)
        static let leafDeep = dynamicColor(light: 0x2C5C33, dark: 0x3E7E46)
        static let terracotta = dynamicColor(light: 0xC2603F, dark: 0xD98A66)
        static let background = dynamicColor(light: 0xF6F8F3, dark: 0x12150F)
        static let surface = dynamicColor(light: 0xFFFFFF, dark: 0x1C2118)
        static let textPrimary = dynamicColor(light: 0x1E241E, dark: 0xEAF0E2)
        static let textSecondary = dynamicColor(light: 0x5B6B5B, dark: 0xA7B6A0)
        static let separator = dynamicColor(light: 0xE4EADD, dark: 0x2A3124)
        static let danger = dynamicColor(light: 0xC0392B, dark: 0xE57368)
        static let warning = dynamicColor(light: 0xCB8A14, dark: 0xF0C860)
    }

    enum Radius {
        static let card: CGFloat = 20
        static let chip: CGFloat = 14
        static let button: CGFloat = 14
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Hero-CTA fill: a quiet leaf gradient instead of a flat system tint.
    static let leafGradient = LinearGradient(
        colors: [Color.leaf, Color.leafDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Dynamic light/dark color from two hex values.
private func dynamicColor(light: Int, dark: Int) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
    })
}

extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

/// A soft, rounded surface used across cards: hairline stroke + a low, wide shadow.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Color.separator.opacity(0.7), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 14, x: 0, y: 4)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// The one green hero CTA per screen: full-width gradient fill with pressed feedback.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Theme.leafGradient)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The quiet companion action: soft leaf-tinted fill, same shape as primary.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.Color.leaf)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Theme.Color.leaf.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// A subtle left-to-right sheen for loading placeholders — reads "in flight,"
/// not "broken."
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width * 1.6)
                }
                .allowsHitTesting(false)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// An SF Symbol in a soft tinted circle — the standard hero / empty-state glyph.
struct IconBadge: View {
    let systemImage: String
    var size: CGFloat = 72
    var tint: Color = Theme.Color.leaf

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: Circle())
    }
}
