import SwiftUI

/// The Day-0 post-purchase payoff (iOS-PRD §8.4/§9): the dormant bud opens into the
/// buddy. Wholesome framing — "look what's growing for you," never punitive.
struct BloomCelebrationView: View {
    @Environment(AppModel.self) private var app
    /// The plant whose bud blooms — its resolved remote sprite if generated, else
    /// the bundled sprite for its species (§8 payoff). `nil` → generic fallback.
    let plant: Plant?
    let onDone: () -> Void

    @State private var bloomed = false
    @State private var showCTA = false

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            if bloomed {
                ConfettiBurst().ignoresSafeArea()
            }
            VStack(spacing: Theme.Space.l) {
                Spacer(minLength: Theme.Space.l)
                bloomStage

                VStack(spacing: Theme.Space.m) {
                    // The one-line answer to "what did I just get", legible even
                    // when this screen is a thumbnail in a store listing.
                    Label("Verdancy Premium", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .kerning(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, 7)
                        .background(Theme.leafGradient, in: Capsule())
                        .elevated(tint: Theme.Color.leafDeep)

                    VStack(spacing: Theme.Space.s) {
                        Text(bloomed ? "Your buddy bloomed" : "Something's growing…")
                            .font(.title.weight(.bold))
                            .foregroundStyle(Theme.Color.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("Everything is unlocked, starting with this one.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .padding(.horizontal, Theme.Space.xl)
                    }
                }
                .opacity(bloomed ? 1 : 0)

                TreesReservedCard(plan: app.lastPurchasedPlan ?? .annual)
                    .padding(.horizontal, Theme.Space.xl)
                    .opacity(bloomed ? 1 : 0)

                Spacer(minLength: Theme.Space.m)
                VStack(spacing: Theme.Space.m) {
                    Button("Let's grow", action: onDone)
                        .buttonStyle(.primary)
                    ShareLink(item: Invite.url, message: Text(Invite.message(code: app.referralCode))) {
                        Label("Share the news", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Color.leaf)
                    }
                }
                .opacity(showCTA ? 1 : 0)
                .padding(.bottom, Theme.Space.xl)
                .padding(.horizontal, Theme.Space.xl)
            }
        }
        .onAppear {
            Analytics.log("bloom_shown")
            Haptics.celebrate()
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.3)) {
                bloomed = true
            }
            withAnimation(.easeIn.delay(1.1)) { showCTA = true }
        }
    }

    /// The bud on a lit stage: a soft radial glow, two rings, and three sparkles
    /// that only appear once it opens. All of it scales up out of the closed bud,
    /// so the reveal is one movement rather than a cross-fade.
    private var bloomStage: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.Color.leaf.opacity(0.28), Theme.Color.leaf.opacity(0)],
                        center: .center, startRadius: 20, endRadius: 175)
                )
                .frame(width: 340, height: 340)
                .scaleEffect(bloomed ? 1.0 : 0.4)
            Circle()
                .strokeBorder(Theme.Color.leaf.opacity(0.22), lineWidth: 1.5)
                .frame(width: 262, height: 262)
                .scaleEffect(bloomed ? 1.0 : 0.5)
            Circle()
                .fill(Theme.Color.leaf.opacity(0.14))
                .frame(width: 224, height: 224)
                .scaleEffect(bloomed ? 1.0 : 0.5)

            ForEach(Array(Self.sparkles.enumerated()), id: \.offset) { _, sparkle in
                Image(systemName: "sparkle")
                    .font(.system(size: sparkle.size, weight: .medium))
                    .foregroundStyle(sparkle.color)
                    .offset(x: sparkle.x, y: sparkle.y)
                    .opacity(bloomed ? 1 : 0)
                    .scaleEffect(bloomed ? 1 : 0.2)
            }

            Group {
                if bloomed {
                    bloomedBud
                } else {
                    Image(BudSprites.dormant)
                        .resizable().interpolation(.none).scaledToFit()
                }
            }
            .frame(width: 196, height: 196)
            .scaleEffect(bloomed ? 1.0 : 0.6)
            .rotationEffect(.degrees(bloomed ? 0 : -10))
        }
        .frame(height: 340)
    }

    /// Hand-placed rather than evenly spaced — a perfect ring of sparkles reads as
    /// a loading spinner.
    private static let sparkles: [(x: CGFloat, y: CGFloat, size: CGFloat, color: Color)] = [
        (-104, -74, 20, Theme.Color.blossom),
        (108, -34, 15, Theme.Color.sun),
        (78, 96, 18, Theme.Color.leaf),
        (-86, 84, 12, Theme.Color.blossom),
    ]

    /// Blooms into the user's actual plant bud: the resolved remote sprite when the
    /// backend has generated it, else the bundled sprite for its species.
    @ViewBuilder private var bloomedBud: some View {
        if AppConfig.budBackendEnabled,
           let urlString = plant?.buddy?.spriteUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().interpolation(.none).scaledToFit()
            } placeholder: {
                bundledBloom
            }
        } else {
            bundledBloom
        }
    }

    private var bundledBloom: some View {
        Image(plant.map { BudSprites.bloomAsset(forArchetype: $0.archetype, species: $0.species) } ?? BudSprites.generic)
            .resizable().interpolation(.none).scaledToFit()
    }
}

/// The Day-0 tree promise, stated honestly: trees follow the payment, never the
/// signup (the webhook's `isPaidPeriod` rule) — so an annual trial's 10 trees are
/// "reserved" until the Day-7 charge, and monthly's tree rides each real payment.
/// The Day-7 payoff itself is `TreesPlantedCelebrationView`.
///
/// Filled forest green rather than another white card: this is the promise the
/// subscription was bought for, and it should read as one solid block from across
/// the room. The deeper gradient keeps it from twinning with the CTA below it.
private struct TreesReservedCard: View {
    let plan: EntitlementService.Plan

    private var count: Int { plan == .annual ? AppConfig.annualTreeGrant : 1 }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { _ in
                    Image(systemName: "tree.fill")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            Text(plan == .annual
                 ? "\(count) trees reserved for your forest"
                 : "Your first tree is on its way")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(plan == .annual
                 ? "They go in the ground with your first payment on Day 7, each with its own certificate."
                 : "One real tree is funded every month you're subscribed, certificates included.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.l)
        .background(Theme.forestGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .elevated(tint: Theme.Color.leafDeep)
    }
}

/// A one-shot confetti rain — this is the Day-0 payoff, it deserves overkill.
/// Slow and staggered on purpose: a fast blast is empty again within a second, so
/// most of the celebration would play to nobody.
struct ConfettiBurst: View {
    private struct Particle: Identifiable {
        let id: Int
        let x: CGFloat
        let delay: Double
        let duration: Double
        let size: CGFloat
        let color: Color
        let spin: Double
        let isRound: Bool
    }

    @State private var fall = false

    private let particles: [Particle] = {
        let palette: [Color] = [
            Theme.Color.leaf, Theme.Color.leafDeep, Theme.Color.terracotta,
            Theme.Color.sun, Theme.Color.blossom,
        ]
        return (0..<42).map { i in
            Particle(
                id: i,
                x: CGFloat.random(in: 0.02...0.98),
                delay: Double.random(in: 0...1.8),
                duration: Double.random(in: 3.6...6.4),
                size: CGFloat.random(in: 6...12),
                color: palette[i % palette.count],
                spin: Double.random(in: 180...540),
                isRound: i % 4 == 0)
        }
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { particle in
                    Group {
                        if particle.isRound {
                            Circle().fill(particle.color)
                                .frame(width: particle.size * 0.7, height: particle.size * 0.7)
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(particle.color)
                                .frame(width: particle.size, height: particle.size * 0.6)
                        }
                    }
                    .rotationEffect(.degrees(fall ? particle.spin : 0))
                    .position(
                        x: particle.x * geo.size.width,
                        y: fall ? geo.size.height + 24 : -24
                    )
                    .animation(
                        .easeIn(duration: particle.duration).delay(particle.delay),
                        value: fall
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { fall = true }
    }
}

#Preview {
    BloomCelebrationView(plant: .sample, onDone: {})
        .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
