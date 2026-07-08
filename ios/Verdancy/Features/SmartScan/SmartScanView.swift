import SwiftUI
import PhotosUI

struct SmartScanView: View {
    @Environment(AppModel.self) private var app
    var body: some View { SmartScanContent(api: app.api) }
}

private struct SmartScanContent: View {
    @Environment(AppModel.self) private var app
    @State private var vm: SmartScanViewModel
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPaywall = false
    @State private var saveContext: SaveContext?

    init(api: APIClient) {
        _vm = State(initialValue: SmartScanViewModel(api: api))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.l) {
                    Picker("Mode", selection: Binding(
                        get: { vm.mode },
                        set: { vm.mode = $0; vm.reset() }
                    )) {
                        ForEach(SmartScanViewModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    content
                }
                .padding(Theme.Space.l)
            }
            .background(Theme.Color.background)
            .navigationTitle("Smart Scan")
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in Task { await vm.scan(image: image) } }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(item: $saveContext) { ctx in
                SavePlantSheet(card: ctx.card, jpeg: ctx.jpeg) {
                    vm.reset()
                    // iOS-PRD §3.2: land where the plant (and its bud) now lives.
                    app.selectedTab = .oasis
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
    }

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .idle:
            // Diagnose is a subscriber-only feature (iOS-PRD §3.2/§7).
            if vm.mode == .diagnose && !app.isSubscribed {
                diagnoseGate
            } else {
                capturePrompt
            }
        case .working:
            VStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: vm.mode == .identify ? "sparkles" : "stethoscope")
                ProgressView().tint(Theme.Color.leaf)
                Text(vm.mode == .identify ? "Identifying…" : "Diagnosing…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .card()
        case let .identified(card, jpeg):
            VStack(spacing: Theme.Space.m) {
                CareCardView(card: card)
                identifyActions(card: card, jpeg: jpeg)
            }
        case let .diagnosed(card):
            VStack(spacing: Theme.Space.m) {
                DiagnosisCardView(card: card)
                Button("Done") { vm.reset() }.buttonStyle(.secondary)
            }
        case .paywall:
            messageCard(
                icon: "leaf.fill",
                title: "Your free scan is used up",
                message: "Subscribe to keep identifying plants and unlock care reminders.",
                primary: ("See plans", { showPaywall = true })
            )
        case .rateLimited:
            messageCard(
                icon: "tortoise.fill",
                title: "You've scanned a lot today",
                message: "Come back tomorrow for more — your garden's safe.",
                primary: ("OK", { vm.reset() })
            )
        case let .error(message):
            messageCard(
                icon: "exclamationmark.triangle.fill",
                title: "Hmm, that didn't work",
                message: message,
                primary: ("Try again", { vm.reset() })
            )
        }
    }

    private var diagnoseGate: some View {
        VStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: "stethoscope")
            VStack(spacing: Theme.Space.xs) {
                Text("Diagnose is a subscriber feature").font(.title3.weight(.semibold))
                Text("Subscribe to get a triage plan for any ailing plant — plus unlimited identify, care reminders, and your blooming buddies.")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Button("See plans") { showPaywall = true }
                .buttonStyle(.primary)
                .padding(.top, Theme.Space.s)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
        .card()
    }

    private var capturePrompt: some View {
        VStack(spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: "camera.viewfinder", size: 84)
                    .padding(Theme.Space.l)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(
                                Theme.Color.leaf.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                            )
                    )
                VStack(spacing: Theme.Space.xs) {
                    Text(vm.mode == .identify ? "Identify a plant" : "Diagnose a problem")
                        .font(.title3.weight(.semibold))
                    Text(vm.mode == .identify
                         ? "Snap a clear, well-lit photo of the leaves."
                         : "Photograph the affected leaves for a triage plan.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .padding(Theme.Space.l)
            .card()

            VStack(spacing: Theme.Space.m) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
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
    }

    @ViewBuilder
    private func identifyActions(card: CareCard, jpeg: Data) -> some View {
        if card.isUnidentified {
            // iOS-PRD §6: never auto-apply a schedule; offer a retake.
            VStack(spacing: Theme.Space.m) {
                Button("Retake photo") { vm.reset() }
                    .buttonStyle(.primary)
                Button("Save as Unidentified") {
                    saveContext = SaveContext(card: card, jpeg: jpeg)
                }
                .buttonStyle(.secondary)
            }
        } else {
            VStack(spacing: Theme.Space.m) {
                Button("Save plant") {
                    saveContext = SaveContext(card: card, jpeg: jpeg)
                }
                .buttonStyle(.primary)
                Button("Discard") { vm.reset() }
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
    }
}

private struct SaveContext: Identifiable {
    let card: CareCard
    let jpeg: Data
    var id: String { card.species + card.commonName }
}
