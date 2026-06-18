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
                            DueRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        Task {
                                            await app.garden.logCare(plant: item.plant, type: item.type)
                                            Haptics.success()
                                        }
                                    } label: { Label("Done", systemImage: "checkmark") }
                                    .tint(Theme.Color.leaf)
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
            Text(greeting)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.Color.textPrimary)
            HStack(spacing: Theme.Space.m) {
                StatChip(icon: "flame.fill", value: "\(streak)", label: "day streak")
                StatChip(icon: "tree.fill", value: "\(trees)", label: "trees")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.s)
    }
}

struct StatChip: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.Color.terracotta)
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

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            CachedAsyncImage(imageRef: item.plant.imageRef, downloadURL: item.plant.downloadUrl)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.plant.displayName).fontWeight(.medium)
                Label(item.type.title, systemImage: item.type.systemImage)
                    .font(.caption).foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Text(item.overdueDays == 0 ? "Due today" : "\(item.overdueDays)d overdue")
                .font(.caption.weight(.medium))
                .foregroundStyle(item.overdueDays == 0 ? Theme.Color.textSecondary : Theme.Color.warning)
        }
        .padding(.vertical, 2)
    }
}

struct TodayEmptyState: View {
    let hasPlants: Bool
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: hasPlants ? "checkmark.seal.fill" : "leaf.fill")
                .font(.system(size: 44)).foregroundStyle(Theme.Color.leaf)
            Text(hasPlants ? "All caught up 🌿" : "Your oasis is empty")
                .font(.headline)
            Text(hasPlants
                 ? "Nothing's due right now. Enjoy your plants!"
                 : "Scan your first plant to start your garden.")
                .font(.subheadline).multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textSecondary)
            if !hasPlants {
                Button("Scan a plant", action: onScan)
                    .buttonStyle(.borderedProminent).tint(Theme.Color.leaf)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

#Preview {
    TodayView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
