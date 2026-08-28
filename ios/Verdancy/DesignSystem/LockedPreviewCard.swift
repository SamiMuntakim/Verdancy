import SwiftUI

/// A "value teaser" card: shows the *shape* of a Premium feature (a care plan, a
/// diagnosis) with its real content redacted and blurred behind a lock, so a free
/// user sees exactly what they'd unlock at the moment they reach for it (iOS-PRD
/// §7/§8). The redaction is deliberate — the content is never readable, so nothing
/// fabricated (a fake care schedule, a fake diagnosis) is ever shown as real.
struct LockedPreviewCard<Content: View>: View {
    let icon: String
    let header: String
    var badge: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Color.leaf)
                    .frame(width: 32, height: 32)
                    .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                Text(header).font(.headline)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.Color.warning.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.Color.warning)
                        .redacted(reason: .placeholder)
                }
            }

            content
                .redacted(reason: .placeholder)
                .blur(radius: 3.5)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity)
        .card()
        .overlay {
            // The lock sits over the redacted content so the card unmistakably reads
            // "there's real value here, unlock to see it."
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "lock.fill").font(.caption.weight(.bold))
                Text("Premium").font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.leafGradient, in: Capsule())
            .shadow(color: Theme.Color.leaf.opacity(0.35), radius: 10, y: 4)
            .padding(.bottom, Theme.Space.l)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
