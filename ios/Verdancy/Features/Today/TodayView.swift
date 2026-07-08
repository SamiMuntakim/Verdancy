import SwiftUI

/// "What does my plant need right now?" (iOS-PRD §3.1). The due-list is computed
/// on-device from cadence + last_done_at; swipe-to-complete logs care optimistically.
struct TodayView: View {
    @Environment(AppModel.self) private var app

    private var totalTrees: Int {
        (app.isSubscribed ? 10 : 0) + app.garden.trees.treesPledged
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GreetingHeader(trees: totalTrees, streak: app.streak.current)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                let due = app.garden.dueItems
                if due.isEmpty {
                    Section {
                        TodayEmptyState(hasPlants: !app.garden.plants.isEmpty) {
                            app.selectedTab = .scan
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section("Due now") {
                        ForEach(due) { item in
                            DueRow(item: item) {
                                Task {
                                    await app.garden.logCare(plant: item.plant, type: item.type)
                                    Haptics.success()
                                }
                            }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        Task {
                                            await app.garden.logCare(plant: item.plant, type: item.type)
                                            Haptics.success()
                                        }
                                    } label: { Label("Done", systemImage: "checkmark") }
                                    .tint(Theme.Color.leaf)
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        app.garden.snooze(plant: item.plant, type: item.type)
                                        Haptics.tap()
                                    } label: { Label("Tomorrow", systemImage: "moon.zzz.fill") }
                                    .tint(Theme.Color.terracotta)
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Color.background)
            .navigationTitle("Today")
            .refreshable { await app.garden.refresh() }
        }
    }
}

struct GreetingHeader: View {
    let trees: Int
    let streak: Int

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(greeting)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            HStack(spacing: Theme.Space.m) {
                StatChip(icon: "flame.fill", tint: Theme.Color.terracotta,
                         value: "\(streak)", label: "day streak")
                StatChip(icon: "tree.fill", tint: Theme.Color.leaf,
                         value: "\(trees)", label: "trees")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.s)
    }
}

struct StatChip: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())
            Text(value).fontWeight(.bold)
            Text(label).font(.caption).foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .card()
    }
}

struct DueRow: View {
    let item: DueItem
    let onComplete: () -> Void

    private var isOverdue: Bool { item.overdueDays > 0 }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            CachedAsyncImage(imageRef: item.plant.imageRef, downloadURL: item.plant.downloadUrl)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.plant.displayName).fontWeight(.semibold)
                Label(item.type.title, systemImage: item.type.systemImage)
                    .font(.caption).foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Text(isOverdue ? "\(item.overdueDays)d late" : "Today")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (isOverdue ? Theme.Color.warning : Theme.Color.leaf).opacity(0.14),
                    in: Capsule()
                )
                .foregroundStyle(isOverdue ? Theme.Color.warning : Theme.Color.leaf)
            // The visible completion path — the swipe stays as the power gesture.
            Button(action: onComplete) {
                Image(systemName: "checkmark.circle")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Theme.Color.leaf)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Mark \(item.type.title.lowercased()) done")
        }
        .padding(.vertical, 4)
    }
}

struct TodayEmptyState: View {
    let hasPlants: Bool
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: hasPlants ? "checkmark.seal.fill" : "leaf.fill")
            VStack(spacing: Theme.Space.xs) {
                Text(hasPlants ? "All caught up 🌿" : "Your oasis is empty")
                    .font(.title3.weight(.semibold))
                Text(hasPlants
                     ? "Nothing's due right now. Enjoy your plants!"
                     : "Scan your first plant to start your garden.")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            if !hasPlants {
                Button("Scan a plant", action: onScan)
                    .buttonStyle(.primary)
                    .padding(.top, Theme.Space.s)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxl)
        .padding(.horizontal, Theme.Space.l)
    }
}

#Preview {
    TodayView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
