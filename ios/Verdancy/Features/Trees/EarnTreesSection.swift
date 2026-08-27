import SwiftUI

/// "How to grow the forest" — every way a tree gets funded, in one place, with
/// real progress where the server tracks it.
///
/// Each row states a rule the backend actually enforces. Nothing here is
/// aspirational copy: if it's listed, a tree gets planted when it happens.
struct EarnTreesSection: View {
    let trees: TreeStatus
    let isSubscribed: Bool
    let onSubscribe: () -> Void

    private var careDone: Int { trees.careOnTime ?? 0 }
    private var streakDays: Int { trees.streak ?? 0 }
    private var streakInterval: Int { trees.streakTreeInterval ?? 30 }

    /// Days into the current 30-day stretch — the streak resets its progress
    /// each time it earns, so show the remainder rather than the raw total.
    private var streakProgress: Double {
        guard streakInterval > 0 else { return 0 }
        return Double(streakDays % streakInterval) / Double(streakInterval)
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            EarnRow(
                icon: "drop.fill",
                title: "Care for your plants",
                detail: "A tree every \(nextCareTarget) on-time care tasks. Only tasks that are "
                      + "actually due count.",
                progress: careProgress,
                progressLabel: "\(careDone) / \(nextCareTarget)")

            EarnRow(
                icon: "flame.fill",
                title: "Keep a care streak",
                detail: "A tree every \(streakInterval) days you keep everything caught up.",
                progress: streakProgress,
                progressLabel: "\(streakDays % streakInterval) / \(streakInterval) days")

            EarnRow(
                icon: "gift.fill",
                title: "Invite a friend",
                detail: "When they subscribe, a tree is planted for each of you.",
                progress: nil,
                progressLabel: nil)

            EarnRow(
                icon: "crown.fill",
                title: isSubscribed ? "Annual subscription" : "Subscribe annually",
                detail: "10 trees for every year subscribed. Monthly plans don't fund trees.",
                progress: nil,
                progressLabel: nil,
                action: isSubscribed ? nil : onSubscribe)
        }
    }

    private var nextCareTarget: Int { trees.nextCareMilestone ?? 25 }
    private var careProgress: Double {
        guard nextCareTarget > 0 else { return 0 }
        return min(1, Double(careDone) / Double(nextCareTarget))
    }
}

private struct EarnRow: View {
    let icon: String
    let title: String
    let detail: String
    let progress: Double?
    let progressLabel: String?
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 30, height: 30)
                .background(Theme.Color.leaf.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Spacer()
                    if let progressLabel {
                        Text(progressLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress)
                        .tint(Theme.Color.leaf)
                        .padding(.top, 2)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}
