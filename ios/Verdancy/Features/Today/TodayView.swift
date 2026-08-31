import SwiftUI

/// "What does my plant need right now?" (iOS-PRD §3.1). The due-list is computed
/// on-device from cadence + last_done_at; swipe-to-complete logs care optimistically.
struct TodayView: View {
    @Environment(AppModel.self) private var app

    /// Server-granted trees only — never a local guess off `isSubscribed`.
    private var totalTrees: Int {
        app.garden.trees.treesPledged
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            let due = app.garden.dueItems
            List {
                Section {
                    GreetingHeader(
                        trees: totalTrees,
                        streak: app.streak.current,
                        // Two tasks on one plant is still one plant asking for you,
                        // so the line counts plants, not rows.
                        plantsDue: Set(due.map(\.plant.plantId)).count)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if due.isEmpty {
                    Section {
                        TodayEmptyState(hasPlants: !app.garden.plants.isEmpty) {
                            app.selectedTab = .scan
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(due) { item in
                            DueRow(item: item) {
                                Task {
                                    await app.garden.logCare(plant: item.plant, type: item.type)
                                    Haptics.success()
                                }
                            }
                                // Each task is its own card rather than a row in one
                                // grouped slab: the plant's photo is the point, and a
                                // divider list buries it.
                                .listRowInsets(EdgeInsets(top: 5, leading: Theme.Space.l,
                                                          bottom: 5, trailing: Theme.Space.l))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
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
                    } header: {
                        SectionHeading(title: "Due now", count: due.count)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(Theme.Space.s)
            // The greeting is the header; the grouped list's own top inset would
            // add ~35pt of nothing between it and the status bar.
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Theme.Color.background)
            // The greeting header IS this screen's title — a large nav title above
            // it would stack two 34pt headings ("Today" over "Good morning").
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Settings is a rare, secondary destination — a toolbar button is
                // the platform-standard home for it, which frees the tab slot for
                // Trees (something users actually come back to).
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.openSettings() } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $app.showSettings) {
                SettingsView(focus: app.settingsFocus).environment(app)
            }
            .refreshable { await app.garden.refresh() }
        }
    }
}

struct GreetingHeader: View {
    let trees: Int
    let streak: Int
    let plantsDue: Int

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }

    /// One plain sentence answering "why am I here?" before the list does.
    private var subtitle: String {
        switch plantsDue {
        case 0: return "Nothing needs you right now."
        case 1: return "1 plant needs you today."
        default: return "\(plantsDue) plants need you today."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(greeting)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            // The two numbers worth coming back for, as filled color blocks: they
            // have to survive being shrunk to an App Store thumbnail.
            HStack(spacing: Theme.Space.m) {
                StatTile(systemImage: "flame.fill", value: "\(streak)",
                         label: "day streak", tone: .ember)
                StatTile(systemImage: "tree.fill", value: "\(trees)",
                         label: trees == 1 ? "real tree" : "real trees", tone: .leaf)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.m)
    }
}

/// A list section title that also carries its count, so "Due now" answers "how
/// many?" without a second glance.
struct SectionHeading: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Color.textPrimary)
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.leaf)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.Color.leaf.opacity(0.14), in: Capsule())
            }
            Spacer()
        }
        .textCase(nil)
        .padding(.bottom, Theme.Space.xs)
    }
}

struct DueRow: View {
    let item: DueItem
    let onComplete: () -> Void

    private var tone: Theme.Tone { item.type.tone }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            // The photo, with the task riding its corner: which plant and which
            // job, read as one object instead of a thumbnail beside a caption.
            CachedAsyncImage(imageRef: item.plant.imageRef, downloadURL: item.plant.downloadUrl)
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: item.type.systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(tone.gradient, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.Color.surface, lineWidth: 2))
                        .offset(x: 6, y: 4)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.plant.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(item.type.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .layoutPriority(1) // the plant's name never loses width to the pill
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: Theme.Space.xs) {
                // Every row in "Due now" is due today, so only being *late* is
                // news. A "Today" pill on every row is chrome, not information.
                if item.overdueDays > 0 {
                    DueStatusPill(days: -item.overdueDays)
                }
                // The visible completion path — the swipe stays as the power gesture.
                CompleteCareButton(tone: tone, action: onComplete)
                    .accessibilityLabel("Mark \(item.type.title.lowercased()) done")
            }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.s)
        .padding(.vertical, 14)
        .card()
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
