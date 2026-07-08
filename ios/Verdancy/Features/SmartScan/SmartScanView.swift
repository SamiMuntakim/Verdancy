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
    @State private var showPlantPicker = false
    @State private var diagnosisSavedTo: String?

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
                CameraPicker { image in
                    diagnosisSavedTo = nil
                    Task { await vm.scan(image: image) }
                }
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
                diagnosisSavedTo = nil
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
        case let .working(image):
            ScanningView(
                image: image,
                label: vm.mode == .identify ? "Identifying…" : "Diagnosing…"
            )
        case let .identified(card, jpeg):
            VStack(spacing: Theme.Space.m) {
                ScannedPhotoHeader(jpeg: jpeg)
                CareCardView(card: card)
                identifyActions(card: card, jpeg: jpeg)
            }
        case let .diagnosed(card, jpeg):
            VStack(spacing: Theme.Space.m) {
                ScannedPhotoHeader(jpeg: jpeg)
                DiagnosisCardView(card: card)
                if let diagnosisSavedTo {
                    Label("Saved to \(diagnosisSavedTo)'s health history",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Color.leaf)
                } else if !app.garden.plants.isEmpty {
                    Button("Save to a plant") { showPlantPicker = true }
                        .buttonStyle(.primary)
                }
                Button("Done") {
                    diagnosisSavedTo = nil
                    vm.reset()
                }
                .buttonStyle(.secondary)
            }
            .sheet(isPresented: $showPlantPicker) {
                PlantPickerSheet(plants: app.garden.plants) { plant in
                    HealthLog.shared.add(card, plantId: plant.plantId)
                    diagnosisSavedTo = plant.displayName
                    Haptics.success()
                }
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

/// The magic moment (iOS-PRD §3.2): the user's own photo with a leaf-green scan
/// line sweeping over it while Gemini works.
private struct ScanningView: View {
    let image: UIImage
    let label: String

    @State private var sweep = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 340)
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
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                sweep = true
            }
        }
    }
}

/// "Which plant is this diagnosis for?" — attaches the triage card to a plant's
/// local health history.
private struct PlantPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plants: [Plant]
    let onPick: (Plant) -> Void

    var body: some View {
        NavigationStack {
            List(plants) { plant in
                Button {
                    onPick(plant)
                    dismiss()
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        CachedAsyncImage(imageRef: plant.imageRef, downloadURL: plant.downloadUrl)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plant.displayName)
                                .fontWeight(.medium)
                                .foregroundStyle(Theme.Color.textPrimary)
                            Text(plant.commonName)
                                .font(.caption)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Which plant?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// The scanned photo shown above the result card, so the verdict reads as
/// "here's what we found in *your* photo."
private struct ScannedPhotoHeader: View {
    let jpeg: Data

    var body: some View {
        if let image = UIImage(data: jpeg) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}
