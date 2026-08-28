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
                .listRowInsets(EdgeInsets())

                Section {
                    ForEach(forest.trees) { tree in
                        CommunityTreeRow(tree: tree)
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
        VStack(spacing: Theme.Space.s) {
            Text("\(forest.totalTrees)")
                .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Color.leaf)
                .contentTransition(.numericText())
            Text(forest.totalTrees == 1
                 ? "real tree planted together"
                 : "real trees planted together")
                .font(.subheadline)
                .foregroundStyle(Theme.Color.textSecondary)
            if forest.co2Tons > 0 {
                Label("\(forest.co2Display) CO₂ compensated", systemImage: "carbon.dioxide.cloud.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.xs)
                    .background(Theme.Color.leaf.opacity(0.10), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

private struct CommunityTreeRow: View {
    let tree: CommunityTree

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            if let image = tree.image {
                CachedAsyncImage(imageRef: image, downloadURL: image)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Theme.Color.leaf.opacity(0.12))
                    Image(systemName: "tree.fill").foregroundStyle(Theme.Color.leaf)
                }
                .frame(width: 56, height: 56)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Tree-Nation's own sentence already names species, project and
                // country, so we show theirs. When there isn't one, this neutral
                // line stands rather than us inventing detail about a real tree.
                Text(tree.message ?? "A tree planted in the Verdancy forest.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Space.s) {
                    if tree.quantity > 1 {
                        Text("×\(tree.quantity)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.Color.leaf)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.Color.leaf.opacity(0.12), in: Capsule())
                    }
                    if let date = tree.plantedDate {
                        Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }

                if let url = tree.certificateURL {
                    Link(destination: url) {
                        Label("Certificate", systemImage: "seal.fill")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }
}

#Preview {
    TreesView().environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
