import SwiftUI

/// The Trees tab: two views of the same promise.
///
/// **Yours** is what this account funded, each tree carrying its own certificate.
/// **Community** is every tree Verdancy has ever planted, read straight from
/// Tree-Nation's public profile — the same page anyone can open themselves. The
/// community number is deliberately theirs rather than one we tally, because a
/// figure the user can check on a site we don't control is the whole point.
struct TreesView: View {
    @Environment(AppModel.self) private var app
    @State private var scope: Scope = .mine

    init() {
        #if DEBUG
        // Screenshot automation: `-treesScope community` opens the Community forest
        // directly (mock mode). Inert in release and outside mock mode.
        let args = CommandLine.arguments
        if AppConfig.useMockAuth, let i = args.firstIndex(of: "-treesScope"),
           i + 1 < args.count, args[i + 1] == "community" {
            _scope = State(initialValue: .community)
        }
        #endif
    }

    enum Scope: String, CaseIterable, Identifiable {
        case mine, community
        var id: String { rawValue }
        var label: String { self == .mine ? "Yours" : "Community" }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch scope {
                case .mine: MyForestList()
                case .community: CommunityForestList()
                }
            }
            .background(Theme.Color.background)
            .navigationTitle("Trees")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.s)
                .background(.bar)
            }
        }
    }
}

// MARK: - Community

/// Everything Verdancy has planted, via our backend's cached proxy of
/// Tree-Nation's public profile feed.
private struct CommunityForestList: View {
    @Environment(AppModel.self) private var app

    @State private var forest: CommunityForest?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        List {
            if let forest {
                Section {
                    CommunityHeader(forest: forest)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Theme.Space.m, leading: Theme.Space.l,
                                          bottom: Theme.Space.xs, trailing: Theme.Space.l))

                Section {
                    ForEach(forest.trees) { tree in
                        CommunityTreeRow(tree: tree)
                            .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.l,
                                                      bottom: Theme.Space.s, trailing: Theme.Space.l))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Recently planted")
                } footer: {
                    Text("Counted by \(AppConfig.plantingPartner), not by us. Open the public "
                         + "profile to check any of it yourself.")
                }

                if let url = forest.profileURL {
                    Section {
                        Link(destination: url) {
                            Label("Open our public \(AppConfig.plantingPartner) profile",
                                  systemImage: "arrow.up.right.square")
                        }
                    }
                }
            } else if isLoading {
                Section {
                    HStack { Spacer(); ProgressView().tint(Theme.Color.leaf); Spacer() }
                        .padding(.vertical, Theme.Space.xl)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if failed {
                Section {
                    // Say nothing rather than guess: an invented number here would
                    // contradict the partner's own public page.
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(Theme.Color.textSecondary)
                        Text("Couldn't load the community forest")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text("Pull to try again.")
                            .font(.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.xl)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Theme.Space.s)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .refreshable { await load(force: true) }
        .task { if forest == nil { await load(force: false) } }
    }

    private func load(force: Bool) async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            forest = try await app.api.communityTrees()
            failed = false
        } catch {
            failed = forest == nil // keep showing good data if a refresh fails
        }
    }
}

private struct CommunityHeader: View {
    let forest: CommunityForest

    var body: some View {
        var stats: [HeroStatStrip.Stat] = [
            .init(value: "\(forest.totalTrees)",
                  label: "planted together",
                  emphasized: true)
        ]
        if forest.co2Tons > 0 {
            stats.append(.init(value: forest.co2Display, label: "CO₂ compensated"))
        }
        return HeroStatStrip(stats: stats)
    }
}

/// One community planting as a full-bleed photo-hero card, matching the "Yours"
/// pane. Tree-Nation's own sentence (which already names the species, project and
/// country) carries the body; the photo, a frosted date/quantity badge, and the
/// certificate link make it a tree rather than a feed row.
private struct CommunityTreeRow: View {
    let tree: CommunityTree

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            photoHeader
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                // Tree-Nation's own sentence names species, project and country, so
                // we show theirs. When there isn't one, this neutral line stands
                // rather than us inventing detail about a real tree.
                Text(tree.message ?? "A tree planted in the Verdancy forest.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if hasLinks {
                    Divider().overlay(Theme.Color.separator)
                    links
                }
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
            .frame(height: 150)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.45)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 100)
            }
            .overlay(alignment: .topTrailing) { metaBadge.padding(Theme.Space.m) }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: Theme.Radius.card,
                    topTrailingRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var speciesImage: some View {
        if let image = tree.image {
            CachedAsyncImage(imageRef: image, downloadURL: image)
        } else {
            // Community entries often arrive without a photo; a branded leaf-gradient
            // canopy reads better than a washed placeholder and gives the floated
            // date badge something dark enough to sit on.
            ZStack {
                Theme.leafGradient
                Image(systemName: "tree.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// Quantity (when Tree-Nation grouped a batch) and the planting date, as one
    /// frosted badge over the photo.
    @ViewBuilder
    private var metaBadge: some View {
        if tree.quantity > 1 || tree.plantedDate != nil {
            HStack(spacing: 5) {
                if tree.quantity > 1 {
                    Text("×\(tree.quantity)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                if let date = tree.plantedDate {
                    Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule())
        }
    }

    // MARK: Body

    private var hasLinks: Bool { tree.certificateURL != nil || tree.collectURL != nil }

    private var links: some View {
        HStack(spacing: Theme.Space.s) {
            if let url = tree.certificateURL {
                actionLink("Certificate", systemImage: "seal.fill", url: url)
                Spacer(minLength: 0)
            }
            if let url = tree.collectURL {
                actionLink("Collect", systemImage: "hand.raised.fill", url: url)
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
}

private extension CommunityTree {
    var collectURL: URL? { collectUrl.flatMap(URL.init(string:)) }
}

#Preview {
    TreesView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
