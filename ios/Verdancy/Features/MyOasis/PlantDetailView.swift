import SwiftUI

/// Plant detail (iOS-PRD §3.3): care schedule + mark-done, the bud, safety/lighting/
/// fertilizer facts, delete. (Growth timeline is deferrable within MVP.)
struct PlantDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let plant: Plant
    @State private var showDeleteConfirm = false

    /// Re-read from the store so optimistic care updates are reflected live.
    private var current: Plant {
        app.garden.plants.first { $0.plantId == plant.plantId } ?? plant
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CachedAsyncImage(imageRef: current.imageRef, downloadURL: current.downloadUrl)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.displayName).font(.title.weight(.bold))
                        Text(current.commonName).foregroundStyle(Theme.Color.textSecondary)
                    }
                    Spacer()
                    BudView(plant: current, isSubscribed: app.isSubscribed, size: 56)
                }

                careSection
                factsSection

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete plant", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.Color.background)
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete \(current.displayName)?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await app.garden.remove(plantId: current.plantId)
                    dismiss()
                }
            }
        } message: {
            Text("This removes the plant, its photos, and its images.")
        }
    }

    private var careSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Care").font(.headline)
            let scheduled = CareType.allCases.filter { current.care.task(for: $0).cadenceDays != nil }
            if scheduled.isEmpty {
                Text("No schedule yet — identify this plant to get care reminders.")
                    .font(.footnote).foregroundStyle(Theme.Color.textSecondary)
            } else {
                ForEach(scheduled, id: \.self) { type in
                    let cadence = current.care.task(for: type).cadenceDays ?? 0
                    HStack {
                        Label("\(type.title) every \(cadence)d", systemImage: type.systemImage)
                            .font(.subheadline)
                        Spacer()
                        Button("Done") {
                            Task {
                                await app.garden.logCare(plant: current, type: type)
                                Haptics.success()
                            }
                        }
                        .buttonStyle(.bordered).tint(Theme.Color.leaf)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
    }

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if current.toxicityLevel?.isConcerning == true {
                Label("Toxic to pets and children if ingested", systemImage: "pawprint.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.danger)
            }
            if let light = current.lightingNeeds, !light.isEmpty {
                factRow(icon: "sun.max.fill", label: "Light", value: light)
            }
            if let fert = current.fertilizerInfo, !fert.isEmpty {
                factRow(icon: "leaf.fill", label: "Fertilizer", value: fert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
    }

    private func factRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: icon).foregroundStyle(Theme.Color.leaf).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Theme.Color.textSecondary)
                Text(value).font(.subheadline)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlantDetailView(plant: .sample)
            .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
    }
}
