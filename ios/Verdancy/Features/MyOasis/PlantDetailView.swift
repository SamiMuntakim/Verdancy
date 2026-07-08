import SwiftUI

/// Plant detail (iOS-PRD §3.3): care schedule + mark-done, the bud, safety/lighting/
/// fertilizer facts, edit, growth timeline, delete.
struct PlantDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let plant: Plant
    @State private var showDeleteConfirm = false
    @State private var showEdit = false
    @State private var showPaywall = false

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
                    // iOS-PRD §8.3: tapping the dormant bud is a paywall moment —
                    // framed as "help it bloom," never punitive.
                    BudView(plant: current, isSubscribed: app.isSubscribed, size: 56)
                        .onTapGesture {
                            if !app.isSubscribed { showPaywall = true }
                        }
                        .sheet(isPresented: $showPaywall) { PaywallView() }
                }

                careSection
                factsSection
                healthSection

                NavigationLink {
                    GrowthTimelineView(plant: current)
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "photo.stack")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Color.leaf)
                            .frame(width: 28, height: 28)
                            .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                        Text("Growth timeline")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .padding(Theme.Space.l)
                    .card()
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete plant", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(Theme.Color.danger)
                .padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.Color.background)
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) { PlantEditView(plant: current) }
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
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: type.systemImage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Color.leaf)
                            .frame(width: 28, height: 28)
                            .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(type.title).font(.subheadline.weight(.medium))
                            Text("Every \(cadence) days")
                                .font(.caption).foregroundStyle(Theme.Color.textSecondary)
                        }
                        Spacer()
                        Button("Done") {
                            Task {
                                await app.garden.logCare(plant: current, type: type)
                                Haptics.success()
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Color.leaf)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.Color.leaf.opacity(0.12), in: Capsule())
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
                Label(PetContext.toxicityWarning, systemImage: "pawprint.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Color.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(
                        Theme.Color.danger.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    )
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

    /// Past diagnoses (local health log) — makes Diagnose feel like an ongoing
    /// medical record, not a one-shot answer.
    @ViewBuilder
    private var healthSection: some View {
        let records = HealthLog.shared.records(for: current.plantId)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Health history").font(.headline)
                ForEach(records) { record in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        SeverityChip(severity: record.severityLevel)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.issue).font(.subheadline.weight(.medium))
                            Text(record.likelyCause)
                                .font(.caption)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        Spacer()
                        if let date = ISO.date(record.at) {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
            .card()
        }
    }

    private func factRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 28, height: 28)
                .background(Theme.Color.leaf.opacity(0.12), in: Circle())
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
