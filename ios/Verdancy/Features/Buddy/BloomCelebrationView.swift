import SwiftUI

/// The Day-0 post-purchase payoff (iOS-PRD §8.4/§9): the dormant bud opens into the
/// buddy. Wholesome framing — "look what's growing for you," never punitive.
struct BloomCelebrationView: View {
    @Environment(AppModel.self) private var app
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
                        .frame(width: 220, height: 220)
                        .scaleEffect(bloomed ? 1.0 : 0.5)
                    Image(bloomed ? BudSprites.generic : BudSprites.dormant)
                        .resizable()
                        .interpolation(.none) // crisp pixel art
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .scaleEffect(bloomed ? 1.0 : 0.7)
                        .rotationEffect(.degrees(bloomed ? 0 : -10))
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
                    ShareLink(item: Invite.url, message: Text(Invite.message(code: app.referralCode))) {
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
        .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
