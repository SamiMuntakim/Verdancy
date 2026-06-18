import SwiftUI

/// Transient celebration when a milestone tree is earned (iOS-PRD §10) — a natural,
/// non-arbitrary sharing moment.
struct TreeEarnedBanner: View {
    let total: Int

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "tree.fill").font(.title3).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("A tree was planted! 🌳")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("\(total) trees in your forest")
                    .font(.caption).foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            ShareLink(item: Invite.url, message: Text(Invite.message)) {
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
