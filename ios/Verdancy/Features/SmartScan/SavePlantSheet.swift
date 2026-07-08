import SwiftUI

/// "Name your plant" → upload the kept photo via presigned PUT → `POST /plants`
/// (iOS-PRD §3.2 save flow). Cadences are dropped for unidentified plants (§6).
struct SavePlantSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let card: CareCard
    let jpeg: Data
    let onSaved: () -> Void

    @State private var nickname: String
    @State private var isSaving = false
    @State private var error: String?

    init(card: CareCard, jpeg: Data, onSaved: @escaping () -> Void) {
        self.card = card
        self.jpeg = jpeg
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
                         : "We'll set up a watering schedule and reminders for you.")
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
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        let name = nickname.trimmingCharacters(in: .whitespaces)
        let nicknameOrNil = name.isEmpty ? nil : name
        do {
            if AppConfig.useMockAuth {
                app.garden.insert(Plant.mock(from: card, nickname: nicknameOrNil))
            } else {
                let ticket = try await app.api.createUpload(kind: "plant")
                try await app.api.uploadImage(to: ticket.uploadUrl, jpeg: jpeg)
                await ImageCache.shared.store(jpeg, imageRef: ticket.imageRef)
                let request = CreatePlantRequest(from: card, imageRef: ticket.imageRef, nickname: nicknameOrNil)
                let plant = try await app.api.savePlant(request)
                app.garden.insert(plant)
            }
            Analytics.log("plant_saved", ["unidentified": String(card.isUnidentified)])
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.userMessage ?? "Couldn't save. Try again."
        }
        isSaving = false
    }
}
