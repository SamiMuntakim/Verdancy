import SwiftUI

/// The garden / collection (iOS-PRD §3.3). Renders from the snapshot instantly,
/// then refreshes. Each card shows the plant's bud (dormant or bloomed).
struct MyOasisView: View {
    @Environment(AppModel.self) private var app

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m)]

    var body: some View {
        NavigationStack {
            Group {
                if app.garden.plants.isEmpty {
                    OasisEmptyState { app.selectedTab = .scan }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Theme.Space.m) {
                            ForEach(app.garden.plants) { plant in
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
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipped()
                BudView(plant: plant, isSubscribed: isSubscribed, size: 40)
                    .padding(Theme.Space.s)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(plant.displayName)
                    .fontWeight(.semibold).lineLimit(1)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(plant.commonName)
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

struct OasisEmptyState: View {
    let onScan: () -> Void
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "leaf.fill").font(.system(size: 52)).foregroundStyle(Theme.Color.leaf)
            Text("Start your oasis").font(.title3.weight(.semibold))
            Text("Scan your first plant — your garden grows from here.")
                .font(.subheadline).multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textSecondary)
            Button("Scan a plant", action: onScan)
                .buttonStyle(.borderedProminent).tint(Theme.Color.leaf)
        }
        .padding(Theme.Space.xl)
    }
}

#Preview {
    MyOasisView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
