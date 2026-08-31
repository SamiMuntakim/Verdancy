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
        /// Water actions — a muted, palette-aware blue (never raw system `.blue`).
        static let water = dynamicColor(light: 0x3E7CA8, dark: 0x6FA8D0)
        /// Direct-sun end of the light-meter spectrum — a warm gold distinct from `warning`.
        static let sun = dynamicColor(light: 0xE0912F, dark: 0xF3B85C)
        /// Deep ends of the two non-green gradients. They exist only as gradient
        /// stops — never reach for them as a standalone fill.
        static let waterDeep = dynamicColor(light: 0x2A5F87, dark: 0x477FA8)
        static let sunDeep = dynamicColor(light: 0xC26A22, dark: 0xD9903F)
        /// Petal pink, for the bloom celebration only.
        static let blossom = dynamicColor(light: 0xD4649B, dark: 0xE590B8)
        /// Ink for text on a filled `warning` chip. Fixed in both modes on purpose,
        /// exactly like the `.white` we put on the dark gradients: what it has to
        /// contrast with is the amber underneath it, not the page. (White on amber
        /// is ~2.9:1 in light mode and unreadable on the brighter dark-mode amber.)
        static let onWarning = staticColor(0x3D2E07)
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
    /// The deeper, cooler forest fill — for filled panels that sit near the one
    /// leaf-gradient CTA and would otherwise read as the same block.
    static let forestGradient = LinearGradient(
        colors: [Color.leafDeep, Color.leaf],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )
    static let waterGradient = LinearGradient(
        colors: [Color.water, Color.waterDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let sunGradient = LinearGradient(
        colors: [Color.sun, Color.sunDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// The streak's warm fill — gold into terracotta.
    static let emberGradient = LinearGradient(
        colors: [Color.sun, Color.terracotta],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The color identity of one domain: a flat tint for text, pills and hairlines,
    /// and the matching gradient for filled glyphs and panels. Water is the same
    /// blue on a care card, a due badge, and a glyph tile because all three read
    /// their color from here — the alternative is the slow drift to six blues.
    struct Tone {
        let tint: SwiftUI.Color
        let gradient: LinearGradient

        static let water = Tone(tint: Color.water, gradient: waterGradient)
        static let sun = Tone(tint: Color.sun, gradient: sunGradient)
        static let leaf = Tone(tint: Color.leaf, gradient: leafGradient)
        static let forest = Tone(tint: Color.leafDeep, gradient: forestGradient)
        static let ember = Tone(tint: Color.terracotta, gradient: emberGradient)
    }
}

/// A color that does not follow the interface style — for ink that has to
/// contrast with a fill rather than with the page.
private func staticColor(_ hex: Int) -> Color { Color(uiColor: UIColor(hex: hex)) }

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
///
/// `tone` tints the fill, the hairline and the shadow, which is how the three care
/// cards read as Water / Light / Nutrients from across the room instead of as three
/// identical white rectangles. Untinted (`nil`) is the neutral default everywhere else.
struct CardBackground: ViewModifier {
    var tone: Theme.Tone?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Theme.Color.surface
                    if let tone { tone.tint.opacity(0.08) }
                }
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    (tone?.tint.opacity(0.22) ?? Theme.Color.separator.opacity(0.7)),
                    lineWidth: 1)
            )
            .elevated(tint: tone?.tint)
    }
}

extension View {
    func card(tone: Theme.Tone? = nil) -> some View { modifier(CardBackground(tone: tone)) }

    /// The app's single elevation. One radius, one offset — a tint only shifts its
    /// hue so a colored surface doesn't cast a grey shadow. Never decoration.
    func elevated(tint: Color? = nil) -> some View {
        shadow(color: (tint ?? .black).opacity(tint == nil ? 0.05 : 0.18), radius: 14, x: 0, y: 4)
    }

    /// iOS 26 Liquid Glass on a shape, with a frosted-material fallback for iOS 17–25.
    /// The one place floating chrome (badges over photos, camera read-outs) gets its
    /// translucency — so the whole app speaks the current platform's material, not a
    /// 2023-era blur.
    @ViewBuilder
    func liquidGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
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

/// The leaf-gradient "impact strip": evenly divided stat columns on the house
/// gradient, with a faint canopy watermark and one soft shadow. Both Trees panes
/// (Yours + Community) use it so their headline figures read as one system —
/// short, balanced, and grandiose without towering over the cards below.
struct HeroStatStrip: View {
    struct Stat: Identifiable {
        let id = UUID()
        var value: String
        var label: String
        var emphasized: Bool = false
    }

    let stats: [Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 {
                    Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 34)
                }
                column(stat)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.s)
        .background {
            ZStack(alignment: .trailing) {
                Theme.leafGradient
                Image(systemName: "tree.fill")
                    .font(.system(size: 110))
                    .foregroundStyle(.white.opacity(0.08))
                    .rotationEffect(.degrees(-6))
                    .offset(x: 26)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: Theme.Color.leafDeep.opacity(0.25), radius: 14, x: 0, y: 6)
    }

    private func column(_ stat: Stat) -> some View {
        VStack(spacing: 2) {
            Text(stat.value)
                .font(.system(size: stat.emphasized ? 34 : 24,
                              weight: stat.emphasized ? .heavy : .bold,
                              design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(stat.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.xs)
    }

    // Namespaced spacing/radius shorthands so this component reads like the rest.
    private typealias Space = Theme.Space
    private typealias Radius = Theme.Radius
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

/// The house icon treatment: an SF Symbol reversed out of a filled gradient
/// squircle. Wherever an icon carries meaning (a care domain, a stat) this replaces
/// the flat tinted circle — a solid color block survives being shrunk to a
/// thumbnail, a 12-percent-alpha glyph does not.
struct GlyphTile: View {
    let systemImage: String
    let tone: Theme.Tone
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                tone.gradient,
                in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

/// A headline figure on a filled gradient block, with its own symbol as a watermark.
/// Used for the counters that carry a screen's story (streak, trees).
struct StatTile: View {
    let systemImage: String
    let value: String
    let label: String
    let tone: Theme.Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background {
            ZStack(alignment: .trailing) {
                tone.gradient
                Image(systemName: systemImage)
                    .font(.system(size: 84))
                    .foregroundStyle(.white.opacity(0.16))
                    .rotationEffect(.degrees(-8))
                    .offset(x: 20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .elevated(tint: tone.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// The one due-status pill: amber when late, leaf when due today, quiet grey when
/// it is still ahead. Every surface that answers "when?" uses this, so the same
/// state never appears in two different shapes.
struct DueStatusPill: View {
    /// Days until due: negative is overdue, 0 is today.
    let days: Int

    private var content: (text: String, tint: Color, solid: Bool) {
        if days < 0 { return ("\(-days)d late", Theme.Color.warning, true) }
        if days == 0 { return ("Today", Theme.Color.leaf, false) }
        return ("in \(days)d", Theme.Color.textSecondary, false)
    }

    var body: some View {
        let style = content
        Text(style.text)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            // A status pill is one line or it is not a pill — never let a narrow
            // row wrap it into "To-/day".
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(style.solid ? Theme.Color.onWarning : style.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(style.solid ? style.tint : style.tint.opacity(0.14), in: Capsule())
    }
}

/// The repeated "I did it" affordance: a filled gradient check with a 44pt target.
/// One shape for the whole app, so completing care always looks the same.
struct CompleteCareButton: View {
    var tone: Theme.Tone = .leaf
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(tone.gradient)
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 36, height: 36)
            .frame(width: 44, height: 44) // 44pt tap target around a 36pt dot
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isBusy)
    }
}
