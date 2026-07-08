import SwiftUI

/// The garden / collection (iOS-PRD §3.3). Renders from the snapshot instantly,
/// then refreshes. Each card shows the plant's bud (dormant or bloomed).
/// Grid ordering — "needs care first" turns the garden into a to-do surface.
enum OasisSort: String, CaseIterable, Identifiable {
    case recent = "Recently added"
    case needsCare = "Needs care first"
    case name = "Name"

    var id: String { rawValue }
}

struct MyOasisView: View {
    @Environment(AppModel.self) private var app
    @State private var searchText = ""
    @AppStorage("verdancy.oasisSort") private var sortRaw = OasisSort.recent.rawValue

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m)]

    private var sort: OasisSort { OasisSort(rawValue: sortRaw) ?? .recent }

    private var displayedPlants: [Plant] {
        var result = app.garden.plants
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter {
                $0.displayName.lowercased().contains(query)
                    || $0.commonName.lowercased().contains(query)
                    || $0.species.lowercased().contains(query)
            }
        }
        switch sort {
        case .recent:
            return result
        case .needsCare:
            let now = Date()
            func urgency(_ plant: Plant) -> TimeInterval {
                CareType.allCases
                    .compactMap { plant.care.task(for: $0).nextDue(now: now)?.timeIntervalSince(now) }
                    .min() ?? .greatestFiniteMagnitude
            }
            return result.sorted { urgency($0) < urgency($1) }
        case .name:
            return result.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.garden.plants.isEmpty {
                    OasisEmptyState { app.selectedTab = .scan }
                } else if displayedPlants.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Theme.Space.m) {
                            ForEach(displayedPlants) { plant in
                                NavigationLink(value: plant) {
                                    PlantCard(plant: plant, isSubscribed: app.isSubscribed)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(Theme.Space.l)
                    }
                }
            }
            .background(Theme.Color.background)
            .navigationTitle("My Oasis")
            .navigationDestination(for: Plant.self) { PlantDetailView(plant: $0) }
            .refreshable { await app.garden.refresh() }
            .searchable(text: $searchText, prompt: "Search your plants")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortRaw) {
                            ForEach(OasisSort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort plants")
                }
            }
        }
    }
}

struct PlantCard: View {
    let plant: Plant
    let isSubscribed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(imageRef: plant.imageRef, downloadURL: plant.downloadUrl)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
                BudView(plant: plant, isSubscribed: isSubscribed, size: 40)
                    .background(.thinMaterial, in: Circle())
                    .padding(Theme.Space.s)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(plant.displayName)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(plant.commonName)
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
        .card()
    }
}

struct OasisEmptyState: View {
    let onScan: () -> Void
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: "leaf.fill", size: 84)
            VStack(spacing: Theme.Space.xs) {
                Text("Start your oasis").font(.title3.weight(.semibold))
                Text("Scan your first plant — your garden grows from here.")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Button("Scan a plant", action: onScan)
                .buttonStyle(.primary)
                .padding(.top, Theme.Space.s)
        }
        .padding(Theme.Space.xxl)
    }
}

#Preview {
    MyOasisView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
