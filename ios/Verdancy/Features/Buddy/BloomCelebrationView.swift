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
                Spacer()
                ZStack {
                    Circle()
                        .fill(Theme.Color.leaf.opacity(0.08))
                        .frame(width: 300, height: 300)
                        .scaleEffect(bloomed ? 1.0 : 0.4)
                    Circle()
                        .fill(Theme.Color.leaf.opacity(0.15))
                        .frame(width: 220, height: 220)
                        .scaleEffect(bloomed ? 1.0 : 0.5)
                    Group {
                        if bloomed {
                            bloomedBud
                        } else {
                            Image(BudSprites.dormant)
                                .resizable().interpolation(.none).scaledToFit()
                        }
                    }
                    .frame(width: 160, height: 160)
                    .scaleEffect(bloomed ? 1.0 : 0.7)
                    .rotationEffect(.degrees(bloomed ? 0 : -10))
                }

                VStack(spacing: Theme.Space.s) {
                    Text(bloomed ? "Your buddy bloomed! 🌸" : "Something's growing…")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Welcome to Verdancy Premium. Everything is unlocked — starting with this one.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, Theme.Space.xl)
                }
                .opacity(bloomed ? 1 : 0)

                TreesReservedCard(plan: app.lastPurchasedPlan ?? .annual)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.m)
                    .opacity(bloomed ? 1 : 0)

                Spacer()
                VStack(spacing: Theme.Space.m) {
                    Button("Let's grow", action: onDone)
                        .buttonStyle(.primary)
                    ShareLink(item: Invite.url, message: Text(Invite.message(code: app.referralCode))) {
                        Label("Share the news", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.medium))
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
        Image(plant.map { BudSprites.bloomAsset(for: $0.species) } ?? BudSprites.generic)
            .resizable().interpolation(.none).scaledToFit()
    }
}

/// The Day-0 tree promise, stated honestly: trees follow the payment, never the
/// signup (the webhook's `isPaidPeriod` rule) — so an annual trial's 10 trees are
/// "reserved" until the Day-7 charge, and monthly's tree rides each real payment.
/// The Day-7 payoff itself is `TreesPlantedCelebrationView`.
private struct TreesReservedCard: View {
    let plan: EntitlementService.Plan

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(spacing: 7) {
                ForEach(0..<(plan == .annual ? AppConfig.annualTreeGrant : 1), id: \.self) { _ in
                    Image(systemName: "tree.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.Color.leaf)
                }
            }
            VStack(spacing: 3) {
                Text(plan == .annual
                     ? "10 trees reserved for your forest"
                     : "Your first tree is on its way")
                    .font(.subheadline.weight(.bold))
                Text(plan == .annual
                     ? "They go in the ground with your first payment on Day 7 — each with its own certificate."
                     : "One real tree is funded every month you're subscribed — certificates included.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.l)
        .card()
    }
}

/// A one-shot confetti rain — this is the Day-0 payoff, it deserves overkill.
struct ConfettiBurst: View {
    private struct Particle: Identifiable {
        let id: Int
        let x: CGFloat
        let delay: Double
        let duration: Double
        let size: CGFloat
        let color: Color
        let spin: Double
    }

    @State private var fall = false

    private let particles: [Particle] = {
        let palette: [Color] = [
            Theme.Color.leaf, Theme.Color.leafDeep, Theme.Color.terracotta, Theme.Color.warning,
        ]
        return (0..<32).map { i in
            Particle(
                id: i,
                x: CGFloat.random(in: 0.02...0.98),
                delay: Double.random(in: 0...0.7),
                duration: Double.random(in: 2.2...3.6),
                size: CGFloat.random(in: 6...11),
                color: palette[i % palette.count],
                spin: Double.random(in: 180...540))
        }
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { particle in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(particle.color)
                        .frame(width: particle.size, height: particle.size * 0.6)
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
