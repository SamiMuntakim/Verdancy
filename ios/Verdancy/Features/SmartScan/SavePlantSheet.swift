import SwiftUI

/// "Name your plant" → upload the kept photo via presigned PUT → `POST /plants`
/// (iOS-PRD §3.2 save flow). Cadences are dropped for unidentified plants (§6).
struct SavePlantSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let card: CareCard
    let jpeg: Data
    /// When false (the first-run flow), skip the subscriber-gated "personalize care"
    /// step (iOS-PRD §8.2) and hand the saved plant straight back for the seedling
    /// reveal. Standard scans keep the guided personalize step.
    var personalizeAfterSave = true
    let onSaved: (Plant) -> Void

    @State private var nickname: String
    @State private var isSaving = false
    @State private var error: String?
    /// Set on a successful save of an identified plant → push the guided
    /// "personalize care" step (iOS-PRD §3.2/§3.3).
    @State private var savedPlant: Plant?

    init(
        card: CareCard,
        jpeg: Data,
        personalizeAfterSave: Bool = true,
        onSaved: @escaping (Plant) -> Void
    ) {
        self.card = card
        self.jpeg = jpeg
        self.personalizeAfterSave = personalizeAfterSave
        self.onSaved = onSaved
        _nickname = State(initialValue: card.isUnidentified ? "" : card.commonName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Space.m) {
                        if let image = UIImage(data: jpeg) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.isUnidentified ? "Unidentified plant" : card.commonName)
                                .font(.subheadline.weight(.semibold))
                            if !card.isUnidentified {
                                Text(card.species.capitalized)
                                    .font(.caption.italic())
                                    .foregroundStyle(Theme.Color.textSecondary)
                            }
                        }
                    }
                }
                Section("Name your plant") {
                    TextField("e.g. Monty the Monstera", text: $nickname)
                }
                Section {
                    Text(card.isUnidentified
                         ? "We'll save this without a care schedule until you identify it."
                         : "Next, tell us where you keep it and we'll build a tailored care plan.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.Color.danger) }
                }
            }
            .navigationTitle("Save Plant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(isSaving)
                }
            }
            .overlay { if isSaving { ProgressView().tint(Theme.Color.leaf) } }
            .navigationDestination(item: $savedPlant) { plant in
                PersonalizeCareView(plant: plant) { onSaved(plant); dismiss() }
                    .navigationBarBackButtonHidden(true)
            }
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        let name = nickname.trimmingCharacters(in: .whitespaces)
        let nicknameOrNil = name.isEmpty ? nil : name
        do {
            let saved: Plant
            if AppConfig.useMockAuth {
                saved = Plant.mock(from: card, nickname: nicknameOrNil)
                app.garden.insert(saved)
            } else {
                let ticket = try await app.api.createUpload(kind: "plant")
                try await app.api.uploadImage(to: ticket.uploadUrl, jpeg: jpeg)
                await ImageCache.shared.store(jpeg, imageRef: ticket.imageRef)
                let request = CreatePlantRequest(from: card, imageRef: ticket.imageRef, nickname: nicknameOrNil)
                saved = try await app.api.savePlant(request)
                app.garden.insert(saved)
            }
            Analytics.log("plant_saved", ["unidentified": String(card.isUnidentified)])
            Haptics.success()
            isSaving = false
            // Identified plants continue into the guided "personalize care" step —
            // unless this is first-run (skip it, straight to the seedling reveal) or
            // the plant is unidentified (no schedule to tailor).
            if card.isUnidentified || !personalizeAfterSave {
                onSaved(saved)
                dismiss()
            } else {
                savedPlant = saved
            }
            return
        } catch {
            self.error = (error as? APIError)?.userMessage ?? "Couldn't save. Try again."
        }
        isSaving = false
    }
}
