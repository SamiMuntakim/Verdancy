import SwiftUI

/// The Day-0 post-purchase payoff (iOS-PRD §8.4/§9): the dormant bud opens into the
/// buddy. Wholesome framing — "look what's growing for you," never punitive.
struct BloomCelebrationView: View {
    let onDone: () -> Void

    @State private var bloomed = false
    @State private var showCTA = false

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Theme.Color.leaf.opacity(0.15))
                        .frame(width: 200, height: 200)
                        .scaleEffect(bloomed ? 1.0 : 0.5)
                    Image(systemName: bloomed ? "camera.macro" : "circle.hexagongrid.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(bloomed ? Theme.Color.leaf : Theme.Color.leafDeep.opacity(0.6))
                        .scaleEffect(bloomed ? 1.0 : 0.7)
                        .rotationEffect(.degrees(bloomed ? 0 : -18))
                }

                VStack(spacing: Theme.Space.s) {
                    Text(bloomed ? "Your buddy bloomed! 🌸" : "Something's growing…")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Welcome to Verdancy. Your plants — and your first 10 real trees — start now.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, Theme.Space.xl)
                }
                .opacity(bloomed ? 1 : 0)

                Spacer()
                VStack(spacing: Theme.Space.s) {
                    Button("Let's grow", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Color.leaf)
                    ShareLink(item: Invite.url, message: Text(Invite.message)) {
                        Label("Share the news", systemImage: "square.and.arrow.up")
                    }
                    .font(.subheadline)
                }
                .opacity(showCTA ? 1 : 0)
                .padding(.bottom, Theme.Space.xl)
                .padding(.horizontal, Theme.Space.xl)
            }
        }
        .onAppear {
            Haptics.celebrate()
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.3)) {
                bloomed = true
            }
            withAnimation(.easeIn.delay(1.1)) { showCTA = true }
        }
    }
}

#Preview {
    BloomCelebrationView(onDone: {})
}
