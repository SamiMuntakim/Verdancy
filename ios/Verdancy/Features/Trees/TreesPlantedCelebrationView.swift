import SwiftUI

/// The Day-7 payoff (iOS-PRD §8.4/§10): the annual subscription's converting
/// payment just funded real trees, and until now the app never said so. A
/// full-screen moment — forest header, certificate card, then the next earn loop
/// (the care-streak tree) so the celebration hands momentum forward. Presented
/// from RootView when `AppModel.pendingTreesPlanted` is set.
struct TreesPlantedCelebrationView: View {
    @Environment(AppModel.self) private var app
    let celebration: TreesPlantedCelebration
    let onDone: () -> Void

    @State private var appeared = false

    private var streakInterval: Int { app.garden.trees.streakTreeInterval ?? 30 }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                certificateCard
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, -Theme.Space.xxl)
                momentumCard
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.l)
                Spacer()
                actions
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xl)
            }

            ConfettiBurst().ignoresSafeArea()
        }
        .onAppear {
            Analytics.log("trees_planted_shown")
            Haptics.celebrate()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.2)) {
                appeared = true
            }
        }
    }

    // MARK: Forest header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Theme.Color.leafDeep, Color(red: 0.12, green: 0.24, blue: 0.14)],
                startPoint: .top, endPoint: .bottom
            )
            // A small forest, mid-tree tallest — the graphic is the grant itself.
            HStack(alignment: .bottom, spacing: Theme.Space.l) {
                Image(systemName: "tree.fill").font(.system(size: 44)).opacity(0.25)
                Image(systemName: "tree.fill").font(.system(size: 72)).opacity(0.55)
                Image(systemName: "tree.fill").font(.system(size: 100))
                Image(systemName: "tree.fill").font(.system(size: 64)).opacity(0.55)
                Image(systemName: "tree.fill").font(.system(size: 40)).opacity(0.25)
            }
            .foregroundStyle(Theme.Color.leaf)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 88)
            .scaleEffect(appeared ? 1 : 0.7, anchor: .bottom)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("IT'S OFFICIAL")
                    .font(.caption.weight(.bold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.Color.leaf)
                Text("You just planted\n\(celebration.count) real trees 🌳")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl + Theme.Space.xl)
            .opacity(appeared ? 1 : 0)
        }
        .frame(height: 340)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Certificate card

    private var certificateCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Color.leafDeep)
                    .frame(width: 44, height: 44)
                    .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your first \(celebration.count) certificates are in")
                        .font(.subheadline.weight(.bold))
                    Text("Planted with \(AppConfig.plantingPartner)")
                        .font(.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            Divider().overlay(Theme.Color.separator)
            factRow(icon: "globe.americas.fill", tint: Theme.Color.leaf,
                    text: "Growing in reforestation projects worldwide")
            factRow(icon: "doc.text.fill", tint: Theme.Color.leaf,
                    text: "Every tree publicly counted, one certificate each")
            factRow(icon: "heart.fill", tint: Theme.Color.terracotta,
                    text: "Yours forever — even if you cancel someday")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
    }

    private func factRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(text).font(.footnote)
        }
    }

    // MARK: Next earn loop

    private var momentumCard: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "flame.fill")
                .font(.title3)
                .foregroundStyle(Theme.Color.terracotta)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tree #\(celebration.total + 1) is closer than you think")
                    .font(.subheadline.weight(.semibold))
                Text("Care for your plants on time for \(streakInterval) days and we plant another one.")
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .card()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: Theme.Space.m) {
            Button("See my forest") {
                app.selectedTab = .trees
                onDone()
            }
            .buttonStyle(.primary)
            ShareLink(item: Invite.url, message: Text(Invite.message(code: app.referralCode))) {
                Label("Share my forest", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.leaf)
            }
        }
        .opacity(appeared ? 1 : 0)
    }
}

#Preview {
    TreesPlantedCelebrationView(
        celebration: TreesPlantedCelebration(count: 10, total: 10),
        onDone: {}
    )
    .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
