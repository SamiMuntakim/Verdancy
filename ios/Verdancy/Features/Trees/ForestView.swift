import SwiftUI

/// "Your forest" (iOS-PRD §10): the real trees planted on the user's behalf, each
/// with its own certificate. The pledge count is a promise; the certificate is the
/// proof — so every planting leads with its certificate link.
struct ForestView: View {
    @Environment(AppModel.self) private var app

    private var plantings: [PlantedTree] { app.garden.trees.plantings }

    var body: some View {
        List {
            if plantings.isEmpty {
                Section {
                    ForestEmptyState(pledged: app.garden.trees.treesPledged)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(plantings) { tree in
                        PlantedTreeRow(tree: tree)
                    }
                } header: {
                    Text("\(plantings.count) real \(plantings.count == 1 ? "tree" : "trees") planted")
                } footer: {
                    Text("Planted with \(AppConfig.plantingPartner). Each certificate is issued for your tree.")
                }
            }

            Section {
                Link("View the public tree counter", destination: AppConfig.treeCounterURL)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.background)
        .navigationTitle("Your forest")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.garden.refresh() }
        .task { if !app.garden.didLoadOnce { await app.garden.refresh() } }
    }
}

private struct PlantedTreeRow: View {
    let tree: PlantedTree

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "tree.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Color.leaf)
                    .frame(width: 30, height: 30)
                    .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(tree.displaySpecies)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
            }

            if let reason = tree.displayReason {
                Text("Earned by: \(reason)")
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            HStack(spacing: Theme.Space.l) {
                if let url = tree.certificateURL {
                    Link(destination: url) {
                        Label("Certificate", systemImage: "seal.fill")
                            .font(.caption.weight(.semibold))
                    }
                }
                if let url = tree.collectURL {
                    Link(destination: url) {
                        Label("Collect", systemImage: "hand.raised.fill")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// Project + planting date, whichever the partner supplied.
    private var subtitle: String? {
        var parts: [String] = []
        if let project = tree.projectName, !project.isEmpty { parts.append(project) }
        if let date = tree.plantedDate {
            parts.append(date.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ForestEmptyState: View {
    let pledged: Int

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.Color.leaf)
            Text(pledged > 0 ? "\(pledged) trees pledged" : "Your forest starts here")
                .font(.headline)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(pledged > 0
                 ? "Certificates appear here as each tree goes in the ground."
                 : "Keep your care streak going — every streak plants a real tree.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

#Preview {
    NavigationStack { ForestView() }
        .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
