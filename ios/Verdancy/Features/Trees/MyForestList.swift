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
                .listRowInsets(EdgeInsets(top: Theme.Space.m, leading: Theme.Space.l,
                                          bottom: Theme.Space.xs, trailing: Theme.Space.l))

                Section {
                    ForEach(plantings) { tree in
                        PlantedTreeRow(tree: tree)
                            .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.l,
                                                      bottom: Theme.Space.s, trailing: Theme.Space.l))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } footer: {
                    Text("Planted with \(AppConfig.plantingPartner). Every certificate is "
                         + "issued by them for your specific tree, and Collect adds it to "
                         + "your own free \(AppConfig.plantingPartner) forest.")
                }
            }

            Section("How to grow the forest") {
                EarnTreesSection(
                    trees: trees,
                    isSubscribed: app.isSubscribed,
                    onSubscribe: { showPaywall = true },
                    onInvite: { app.openSettings(focus: .invite) })
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                Link("View the public tree counter", destination: AppConfig.treeCounterURL)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Theme.Space.s)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.background)
        .refreshable { await app.garden.refresh() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task { if !app.garden.didLoadOnce { await app.garden.refresh() } }
    }
}

/// Headline impact, made to feel like an achievement rather than a stat row: the
/// shared leaf-gradient strip with the tree count emphasized and the combined
/// lifetime CO₂ / where-they-grow figures balanced evenly beside it.
private struct ImpactHeader: View {
    let trees: TreeStatus

    private var treeCount: Int { trees.plantings.count }

    var body: some View {
        var stats: [HeroStatStrip.Stat] = [
            .init(value: "\(treeCount)",
                  label: treeCount == 1 ? "real tree" : "real trees",
                  emphasized: true)
        ]
        if trees.lifetimeCo2Kg > 0 {
            stats.append(.init(value: "\(trees.lifetimeCo2Kg) kg", label: "CO₂ absorbed"))
        }
        if let place = trees.countries.first {
            stats.append(.init(
                value: place,
                label: trees.countries.count > 1
                    ? "+\(trees.countries.count - 1) more" : "planted"))
        }
        return HeroStatStrip(stats: stats)
    }
}

/// One planted tree as a full-bleed photo-hero card (matching the scan result):
/// the species photo carries it, the name and place read reversed-out over a
/// scrim, a frosted lifetime-CO₂ badge floats on the image, and the third-party
/// links (certificate / collect / field updates) sit in the body beneath. Bigger
/// photo, more presence — this is a tree you funded, not a line item.
private struct PlantedTreeRow: View {
    let tree: PlantedTree

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            photoHeader
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let reason = tree.displayReason {
                    chip(reason, icon: "sparkles")
                }
                Divider().overlay(Theme.Color.separator)
                actionLinks
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Color.separator.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 6)
    }

    // MARK: Photo header

    private var photoHeader: some View {
        speciesImage
            .frame(maxWidth: .infinity)
            .frame(height: 188)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.2), .black.opacity(0.68)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 140)
            }
            .overlay(alignment: .topTrailing) { co2Badge.padding(Theme.Space.m) }
            .overlay(alignment: .bottomLeading) { nameBlock.padding(Theme.Space.l) }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: Theme.Radius.card,
                    topTrailingRadius: Theme.Radius.card, style: .continuous))
    }

    /// Real photo of the species when the partner supplied one; a calm leaf-gradient
    /// panel otherwise. Species repeat across rows and launches (a forest is often
    /// one or two species), so this goes through the same on-disk cache as plant
    /// photos — keyed by the stable CDN URL — rather than re-downloading each time.
    @ViewBuilder
    private var speciesImage: some View {
        if let image = tree.speciesImage {
            CachedAsyncImage(imageRef: image, downloadURL: image)
        } else {
            ZStack {
                Theme.leafGradient
                Image(systemName: "tree.fill")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tree.displaySpecies)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            if let latin = tree.displayLatin {
                Text(latin)
                    .font(.subheadline.italic())
                    .foregroundStyle(.white.opacity(0.9))
            }
            if let subtitle {
                Label(subtitle, systemImage: "mappin.and.ellipse")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 1)
    }

    /// Lifetime CO₂ as a frosted badge over the photo — the impact, not a footnote.
    @ViewBuilder
    private var co2Badge: some View {
        if let co2 = tree.lifeTimeCo2, co2 > 0 {
            HStack(spacing: 5) {
                Image(systemName: "leaf.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.Color.leaf)
                Text("~\(co2) kg CO₂")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule())
        }
    }

    // MARK: Body

    private var actionLinks: some View {
        HStack(spacing: Theme.Space.s) {
            if let url = tree.certificateURL {
                actionLink("Certificate", systemImage: "seal.fill", url: url)
                Spacer(minLength: 0)
            }
            if let url = tree.collectURL {
                actionLink("Collect", systemImage: "hand.raised.fill", url: url)
                Spacer(minLength: 0)
            }
            if let url = tree.projectURL {
                actionLink("Field updates", systemImage: "photo.on.rectangle.angled", url: url)
            }
        }
    }

    private func actionLink(_ title: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.Color.leaf)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .background(Theme.Color.leaf.opacity(0.10), in: Capsule())
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
