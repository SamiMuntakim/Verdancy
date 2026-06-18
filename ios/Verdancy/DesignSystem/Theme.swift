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
        static let card: CGFloat = 18
        static let chip: CGFloat = 12
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }
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

/// A soft, rounded surface used across cards.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 3)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
