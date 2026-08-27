import SwiftUI
import PhotosUI

/// The post-sign-up first-run flow (iOS-PRD §8.2): a brand-new account is led
/// straight into scanning their first real plant ("plant your seed"), then shown a
/// dormant **seedling** of their very own bud. Subscribing blooms it (§8.4); "maybe
/// later" drops them into the app with the seedling still forming — the open loop.
///
/// Coordinator only: the scan lives in `FirstScanView`, the reveal in
/// `SeedlingRevealView`, and the bloom reuses `BloomCelebrationView` via
/// `app.pendingBloom` (presented from `RootView`).
struct FirstRunView: View {
    @Environment(AppModel.self) private var app

    private enum Step: Equatable { case scan, reveal }
    @State private var step: Step = .scan
    @State private var savedPlant: Plant?
    @State private var showPaywall = false

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            switch step {
            case .scan:
                FirstScanView(api: app.api) { plant in
                    savedPlant = plant
                    withAnimation(.smooth) { step = .reveal }
                }
                .transition(.opacity)
            case .reveal:
                if let plant = savedPlant {
                    SeedlingRevealView(
                        plant: plant,
                        onBloom: {
                            Analytics.log("seedling_bloom_tapped")
                            showPaywall = true
                        },
                        onLater: {
                            Analytics.log("seedling_later_tapped")
                            app.completeFirstRun()
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .onChange(of: showPaywall) { _, shown in
            // Paywall closed without subscribing (Close or swipe-down) → let them in
            // with the seedling still dormant. If they DID subscribe, the bloom's
            // completion finishes first-run instead, so don't double up here.
            if !shown && !app.isSubscribed { app.completeFirstRun() }
        }
        .onAppear { Analytics.log("first_run_started") }
    }
}

// MARK: - First scan ("plant your seed")

/// A focused, identify-only first scan. Deliberately leaner than the full Smart Scan
/// tab (no mode picker, no diagnose gate): the single job is to get the aha — "that's
/// what my plant is" — and save it, which plants the seed.
private struct FirstScanView: View {
    @Environment(AppModel.self) private var app
    @State private var vm: SmartScanViewModel
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var saveContext: SaveContext?

    let onSaved: (Plant) -> Void

    init(api: APIClient, onSaved: @escaping (Plant) -> Void) {
        self.onSaved = onSaved
        // Force identify — the care plan (diagnose/personalize) is the first
        // subscriber-gated moment, which comes after this.
        let model = SmartScanViewModel(api: api)
        model.mode = .identify
        _vm = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                content
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Color.background)
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in Task { await vm.scan(image: image) } }
                .ignoresSafeArea()
        }
        .sheet(item: $saveContext) { ctx in
            SavePlantSheet(card: ctx.card, jpeg: ctx.jpeg, personalizeAfterSave: false) { plant in
                onSaved(plant)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await vm.scan(image: image)
                }
                photoItem = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .idle:
            capturePrompt
        case let .working(image):
            FirstScanScanningView(image: image)
        case let .identified(card, jpeg):
            VStack(spacing: Theme.Space.m) {
                CareCardView(card: card)
                actions(card: card, jpeg: jpeg)
            }
        case .paywall, .rateLimited:
            // A free account gets its first identify; if the daily allowance is
            // somehow spent, don't dead-end onboarding — let them in.
            messageCard(
                icon: "leaf.fill",
                title: "Let's pick this up in a moment",
                message: "Your garden's ready. You can scan your first plant from the Scan tab.",
                primary: ("Continue", { app.completeFirstRun() })
            )
        case let .error(message):
            messageCard(
                icon: "exclamationmark.triangle.fill",
                title: "Hmm, that didn't work",
                message: message,
                primary: ("Try again", { vm.reset() })
            )
        case .diagnosed:
            // Not reachable in identify-only first run.
            capturePrompt
        }
    }

    private var capturePrompt: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: "camera.viewfinder", size: 108)
                    .padding(Theme.Space.l)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(
                                Theme.Color.leaf.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                            )
                    )
                VStack(spacing: Theme.Space.s) {
                    Text("Plant your first seed 🌱")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Point your camera at any plant. We'll name it, flag anything toxic, and grow you a little buddy for it.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.xl)
            .card()

            VStack(spacing: Theme.Space.m) {
                Button { showCamera = true } label: {
                    Label("Scan a plant", systemImage: "camera.fill")
                }
                .buttonStyle(.primary)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .foregroundStyle(Theme.Color.leaf)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.Color.leaf.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                }
            }
        }
        .padding(.top, Theme.Space.xxl)
    }

    @ViewBuilder
    private func actions(card: CareCard, jpeg: Data) -> some View {
        if card.isUnidentified {
            // iOS-PRD §6: never fake a schedule. Nudge a clearer photo, but still let
            // them plant the seed so the reveal lands.
            VStack(spacing: Theme.Space.m) {
                Button("Retake for a better match") { vm.reset() }
                    .buttonStyle(.primary)
                Button("Save it anyway") {
                    saveContext = SaveContext(card: card, jpeg: jpeg)
                }
                .buttonStyle(.secondary)
            }
        } else {
            VStack(spacing: Theme.Space.m) {
                Button("Plant this seed") {
                    saveContext = SaveContext(card: card, jpeg: jpeg)
                }
                .buttonStyle(.primary)
                Button("Scan a different plant") { vm.reset() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    private func messageCard(
        icon: String, title: String, message: String, primary: (String, () -> Void)
    ) -> some View {
        VStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: icon)
            VStack(spacing: Theme.Space.xs) {
                Text(title).font(.title3.weight(.semibold))
                Text(message).font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Button(primary.0, action: primary.1)
                .buttonStyle(.primary)
                .padding(.top, Theme.Space.s)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
        .card()
        .padding(.top, Theme.Space.xxl)
    }
}

/// Identifiable wrapper so the save sheet presents on a scanned result.
private struct SaveContext: Identifiable {
    let card: CareCard
    let jpeg: Data
    var id: String { card.species + card.commonName }
}

/// The scan-in-progress moment, mirroring Smart Scan's sweep line but standalone.
private struct FirstScanScanningView: View {
    let image: UIImage
    @State private var sweep = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                Theme.Color.leaf.opacity(0),
                                Theme.Color.leaf.opacity(0.65),
                                Theme.Color.leaf.opacity(0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 80)
                        .offset(y: sweep ? geo.size.height - 80 : 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .allowsHitTesting(false)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.Color.leaf.opacity(0.5), lineWidth: 1.5)
                )
            HStack(spacing: Theme.Space.s) {
                ProgressView().tint(Theme.Color.leaf)
                Text("Identifying your plant…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .padding(.top, Theme.Space.l)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                sweep = true
            }
        }
    }
}

// MARK: - Seedling reveal (the pop-up payoff)

/// The open-loop moment (iOS-PRD §8.2/§9): the plant they just saved has grown a
/// dormant **seedling** of its own bud — visibly *theirs*, clearly "forming." The
/// promise: subscribe and watch it bloom. Framing is always "look what's growing for
/// you," never punitive (§8 framing rule).
struct SeedlingRevealView: View {
    let plant: Plant
    let onBloom: () -> Void
    let onLater: () -> Void

    @State private var appeared = false
    @State private var sway = false
    @State private var showCTA = false

    var body: some View {
        ZStack {
            // A soft radial glow so the seedling feels spotlit, not clinical.
            RadialGradient(
                colors: [Theme.Color.leaf.opacity(0.18), Theme.Color.background],
                center: .center, startRadius: 20, endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: Theme.Space.l) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Theme.Color.leaf.opacity(0.08))
                        .frame(width: 300, height: 300)
                        .scaleEffect(appeared ? 1 : 0.5)
                    Circle()
                        .fill(Theme.Color.leaf.opacity(0.14))
                        .frame(width: 210, height: 210)
                        .scaleEffect(appeared ? 1 : 0.55)
                    Image(BudSprites.dormant)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 150, height: 150)
                        .scaleEffect(appeared ? 1 : 0.2)
                        .rotationEffect(.degrees(sway ? 3 : -3))
                        .shadow(color: Theme.Color.leaf.opacity(0.25), radius: 20, y: 8)
                }

                VStack(spacing: Theme.Space.s) {
                    Text("A seedling is forming for \(plant.displayName) 🌱")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Your plant just grew its own little buddy. Start your free trial to watch it bloom, and we'll plant your first 10 real trees.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, Theme.Space.xl)
                }
                .opacity(appeared ? 1 : 0)

                Spacer()

                VStack(spacing: Theme.Space.m) {
                    Button("Bloom my buddy", action: onBloom)
                        .buttonStyle(.primary)
                    Button("Maybe later", action: onLater)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .opacity(showCTA ? 1 : 0)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
            }
        }
        .onAppear {
            Analytics.log("seedling_revealed")
            Haptics.success()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { sway = true }
            withAnimation(.easeIn.delay(0.7)) { showCTA = true }
        }
    }
}

#Preview("Seedling reveal") {
    SeedlingRevealView(plant: .sample, onBloom: {}, onLater: {})
        .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
}
