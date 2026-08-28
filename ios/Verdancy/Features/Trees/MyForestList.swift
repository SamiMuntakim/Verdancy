import SwiftUI

/// The "Yours" pane of the Trees tab (iOS-PRD §10): the real trees planted on
/// this account's behalf.
/// The pledge count is a promise; this screen is the proof — every tree carries
/// its species photo, where it grows, its lifetime CO₂, and three third-party
/// links: the per-tree certificate, the collect page (which claims the tree into
/// the user's own free Tree-Nation forest), and the project's field updates with
/// photos from the ground. All of it lives on the partner's site, not ours —
/// that's what makes it verifiable rather than a number we typed.
struct MyForestList: View {
    @Environment(AppModel.self) private var app
    @State private var showPaywall = false

    private var trees: TreeStatus { app.garden.trees }
    private var plantings: [PlantedTree] { trees.plantings }

    var body: some View {
        List {
            if plantings.isEmpty {
                Section {
                    ForestEmptyState(pledged: trees.treesPledged)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ImpactHeader(trees: trees)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

                Section {
                    ForEach(plantings) { tree in
                        PlantedTreeRow(tree: tree)
                    }
                } footer: {
                    Text("Planted with \(AppConfig.plantingPartner). Every certificate is "
                         + "issued by them for your specific tree, and Collect adds it to "
                         + "your own free \(AppConfig.plantingPartner) forest.")
                }
            }

            Section("How to grow the forest") {
                EarnTreesSection(trees: trees, isSubscribed: app.isSubscribed) {
                    showPaywall = true
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                Link("View the public tree counter", destination: AppConfig.treeCounterURL)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.background)
        .refreshable { await app.garden.refresh() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task { if !app.garden.didLoadOnce { await app.garden.refresh() } }
    }
}

/// Headline impact: tree count, combined lifetime CO₂, and where they grow.
private struct ImpactHeader: View {
    let trees: TreeStatus

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            stat(value: "\(trees.plantings.count)",
                 label: trees.plantings.count == 1 ? "real tree" : "real trees",
                 icon: "tree.fill")
            if trees.lifetimeCo2Kg > 0 {
                stat(value: "\(trees.lifetimeCo2Kg) kg",
                     label: "CO₂ absorbed over their lives",
                     icon: "carbon.dioxide.cloud.fill")
            }
            if let place = trees.countries.first {
                stat(value: place,
                     label: trees.countries.count > 1
                        ? "+ \(trees.countries.count - 1) more"
                        : "where they grow",
                     icon: "globe.europe.africa.fill")
            }
        }
        // Sized by the tallest tile so all three share one height — a wordier
        // label must not make its neighbors look misaligned.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Theme.Space.s)
    }

    private func stat(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.xs)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

private struct PlantedTreeRow: View {
    let tree: PlantedTree

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                speciesThumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(tree.displaySpecies)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    if let latin = tree.displayLatin {
                        Text(latin)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
            }

            HStack(spacing: Theme.Space.s) {
                if let co2 = tree.lifeTimeCo2, co2 > 0 {
                    chip("~\(co2) kg CO₂", icon: "leaf.fill")
                }
                if let reason = tree.displayReason {
                    chip(reason, icon: "sparkles")
                }
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
                if let url = tree.projectURL {
                    Link(destination: url) {
                        Label("Field updates", systemImage: "photo.on.rectangle.angled")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// Real photo of the species when the partner supplied one; leaf glyph otherwise.
    /// Species repeat across rows and launches (a forest is often one or two
    /// species), so this goes through the same on-disk cache as plant photos —
    /// keyed by the stable CDN URL — rather than re-downloading every appearance.
    @ViewBuilder
    private var speciesThumbnail: some View {
        if let image = tree.speciesImage {
            CachedAsyncImage(imageRef: image, downloadURL: image)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        } else {
            thumbnailFallback
                .frame(width: 44, height: 44)
        }
    }

    private var thumbnailFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Color.leaf.opacity(0.12))
            Image(systemName: "tree.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
        }
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 3)
            .background(Theme.Color.leaf.opacity(0.08), in: Capsule())
    }

    /// Where and when: "Mkussu Forest, Tanzania · Aug 27, 2026".
    private var subtitle: String? {
        var place = [tree.projectName, tree.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if let date = tree.plantedDate {
            let day = date.formatted(.dateTime.month(.abbreviated).day().year())
            place = place.isEmpty ? day : "\(place) · \(day)"
        }
        return place.isEmpty ? nil : place
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
                 : "Keep your care streak going. Every streak plants a real tree.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

#Preview {
    NavigationStack { MyForestList() }
        .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
