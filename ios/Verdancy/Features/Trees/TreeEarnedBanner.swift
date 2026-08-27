import SwiftUI

/// Transient celebration when a tree is earned (iOS-PRD §10) — a natural,
/// non-arbitrary sharing moment. A streak grant names the reason ("your 7-day
/// streak planted a tree"); a milestone grant keeps the generic line.
struct TreeEarnedBanner: View {
    @Environment(AppModel.self) private var app
    let celebration: TreeCelebration

    private var title: String {
        guard let days = celebration.streakDays, days > 0 else { return "A tree was planted! 🌳" }
        return "Your \(days)-day streak planted a tree! 🌳"
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "tree.fill").font(.title3).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("\(celebration.total) trees in your forest")
                    .font(.caption).foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            ShareLink(item: Invite.url, message: Text(Invite.message(code: app.referralCode))) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.white)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.Color.leafDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, Theme.Space.l)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
