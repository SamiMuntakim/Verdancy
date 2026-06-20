import SwiftUI

/// Edit a plant (iOS-PRD §3.3/§13): rename + adjust the water/fertilize cadences via
/// `PATCH /plants/{id}`. (Clearing a schedule to "none" isn't surfaced here for MVP.)
struct PlantEditView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let plant: Plant
    @State private var nickname: String
    @State private var water: Int
    @State private var fertilize: Int
    @State private var saving = false
    @State private var error: String?

    init(plant: Plant) {
        self.plant = plant
        _nickname = State(initialValue: plant.nickname ?? plant.commonName)
        _water = State(initialValue: plant.care.water.cadenceDays ?? 7)
        _fertilize = State(initialValue: plant.care.fertilize.cadenceDays ?? 30)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Nickname", text: $nickname)
                }
                Section("Schedule") {
                    Stepper("Water every \(water) days", value: $water, in: 1...365)
                    Stepper("Fertilize every \(fertilize) days", value: $fertilize, in: 1...365)
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.Color.danger) }
                }
            }
            .navigationTitle("Edit Plant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .overlay { if saving { ProgressView().tint(Theme.Color.leaf) } }
        }
    }

    private func save() async {
        saving = true
        error = nil
        let name = nickname.trimmingCharacters(in: .whitespaces)
        let nicknameOrNil = name.isEmpty ? nil : name
        do {
            if AppConfig.useMockAuth {
                let care = CareMap(
                    water: CareTask(cadenceDays: water, lastDoneAt: plant.care.water.lastDoneAt),
                    fertilize: CareTask(cadenceDays: fertilize, lastDoneAt: plant.care.fertilize.lastDoneAt),
                    prune: plant.care.prune)
                app.garden.update(plant.edited(nickname: nicknameOrNil, care: care))
            } else {
                let request = UpdatePlantRequest(
                    nickname: nicknameOrNil, waterCadenceDays: water,
                    fertilizeCadenceDays: fertilize, pruneCadenceDays: nil)
                let updated = try await app.api.updatePlant(plantId: plant.plantId, request)
                app.garden.update(updated)
            }
            Haptics.success()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.userMessage ?? "Couldn't save. Try again."
        }
        saving = false
    }
}
