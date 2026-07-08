import WidgetKit
import SwiftUI

/// "Due today" home-screen widget (retention lever: the garden asks for you from
/// the home screen, no notification needed). Renders the summary the app writes
/// to the App Group — no networking, no auth, no images.
@main
struct VerdancyWidgetBundle: WidgetBundle {
    var body: some Widget {
        DueTodayWidget()
    }
}

struct DueTodayWidget: Widget {
    let kind = "DueTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DueProvider()) { entry in
            DueTodayView(entry: entry)
                .containerBackground(Theme.Color.surface, for: .widget)
        }
        .configurationDisplayName("Due today")
        .description("See which plants need you right now.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DueEntry: TimelineEntry {
    let date: Date
    let summary: WidgetShared.Summary?
}

struct DueProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueEntry {
        DueEntry(date: .now, summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DueEntry) -> Void) {
        completion(DueEntry(date: .now, summary: WidgetShared.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DueEntry>) -> Void) {
        let entry = DueEntry(date: .now, summary: WidgetShared.read())
        // The app reloads timelines on every garden change; this fallback refresh
        // at the next midnight keeps "due today" truthful if the app isn't opened.
        let midnight = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_460)
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

extension WidgetShared.Summary {
    static let placeholder = WidgetShared.Summary(
        items: [
            .init(plantName: "Monty", task: "Water", systemImage: "drop.fill", overdueDays: 0),
            .init(plantName: "Sunny", task: "Fertilize", systemImage: "leaf.fill", overdueDays: 1),
        ],
        dueCount: 2, plantCount: 4, streak: 6, generatedAt: .now)
}

struct DueTodayView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DueEntry

    private var summary: WidgetShared.Summary? { entry.summary }
    private var maxRows: Int { family == .systemSmall ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let summary, !summary.items.isEmpty {
                ForEach(Array(summary.items.prefix(maxRows).enumerated()), id: \.offset) { _, item in
                    row(item)
                }
            } else {
                Text(summary == nil
                     ? "Open Verdancy to grow your garden."
                     : "All caught up — your plants are happy 🌿")
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "leaf.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
            Text(headline)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
            Spacer()
            if let streak = summary?.streak, streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                    Text("\(streak)")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.Color.terracotta)
            }
        }
    }

    private var headline: String {
        guard let summary else { return "Verdancy" }
        if summary.items.isEmpty { return "All caught up" }
        return summary.dueCount == 1 ? "1 task due" : "\(summary.dueCount) tasks due"
    }

    private func row(_ item: WidgetShared.Summary.Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 18, height: 18)
                .background(Theme.Color.leaf.opacity(0.12), in: Circle())
            Text(item.plantName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.overdueDays > 0 ? "\(item.overdueDays)d late" : item.task)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.overdueDays > 0 ? Theme.Color.warning : Theme.Color.textSecondary)
        }
    }
}
