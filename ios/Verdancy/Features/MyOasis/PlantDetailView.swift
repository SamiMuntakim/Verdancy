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
    @State private var showPersonalize = false

    /// Re-read from the store so optimistic care updates are reflected live.
    private var current: Plant {
        app.garden.plants.first { $0.plantId == plant.plantId } ?? plant
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                heroHeader

                Group {
                    careContent
                    // Screenshot anchor: scroll here to reveal the full care plan
                    // (Water · Light · Nutrients) with just a sliver of the hero.
                    Color.clear.frame(height: 0).id("careBottom")
                    if hasFacts { factsSection }
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

                // Light meter (premium): subscribers open it; free users see the paywall.
                if app.isSubscribed {
                    NavigationLink { LightMeterView(plant: current) } label: {
                        lightMeterRow(locked: false)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { showPaywall = true } label: { lightMeterRow(locked: true) }
                        .buttonStyle(.plain)
                }

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
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.l)
            }
        }
        .coordinateSpace(name: "detailScroll")
        #if DEBUG
        .onAppear {
            guard AppConfig.useMockAuth,
                  CommandLine.arguments.contains("-plantScrolled") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation { proxy.scrollTo("careBottom", anchor: .bottom) }
            }
        }
        #endif
        .background(Theme.Color.background)
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) { PlantEditView(plant: current) }
        .sheet(isPresented: $showPersonalize) {
            NavigationStack {
                PersonalizeCareView(plant: current) { showPersonalize = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showPersonalize = false }
                        }
                    }
            }
        }
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
    }

    /// The light-meter entry row (mirrors the growth-timeline row). Shows a lock for
    /// free users, who are routed to the paywall instead of the meter.
    private func lightMeterRow(locked: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "sun.max.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 28, height: 28)
                .background(Theme.Color.leaf.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Measure this spot's light")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                if locked {
                    Text("Premium")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.Color.leaf)
                }
            }
            Spacer()
            Image(systemName: locked ? "lock.fill" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(Theme.Space.l)
        .card()
    }

    /// Full-bleed stretchy hero: the photo grows on pull-down, with a scrim, the
    /// name overlaid, and the bud living on the photo (iOS-PRD §8.3: tapping the
    /// dormant bud is a paywall moment — "help it bloom," never punitive).
    private var heroHeader: some View {
        GeometryReader { geo in
            let offset = geo.frame(in: .named("detailScroll")).minY
            let stretch = max(0, offset)
            ZStack(alignment: .bottom) {
                CachedAsyncImage(imageRef: current.imageRef, downloadURL: current.downloadUrl)
                    .frame(width: geo.size.width, height: 300 + stretch)
                    .clipped()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 150)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.displayName)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                        if let subtitle = current.displaySubtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    Spacer()
                    BudView(plant: current, isSubscribed: app.isSubscribed, size: 56)
                        .background(.thinMaterial, in: Circle())
                        .onTapGesture {
                            if !app.isSubscribed { showPaywall = true }
                        }
                }
                .padding(Theme.Space.l)
            }
            .offset(y: -stretch)
        }
        .frame(height: 300)
    }

    /// Either the tailored care plan (+ a mark-done schedule), or a prompt to
    /// finish personalizing care (iOS-PRD §3.3).
    @ViewBuilder
    private var careContent: some View {
        if let plan = current.carePlan {
            // Interactive mode: each card carries its own due status + Done, so
            // there's no separate "Log care" list restating the cadences.
            CarePlanView(plan: plan, plant: current) { type in
                await app.garden.logCare(plant: current, type: type)
                Haptics.success()
            }
            Button("Update care plan") { showPersonalize = true }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Color.leaf)
                .frame(maxWidth: .infinity)
        } else {
            personalizeCTA
        }
    }

    /// The "Finish personalizing care" prompt shown until a plan is generated.
    private var personalizeCTA: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Color.leaf)
                    .frame(width: 28, height: 28)
                    .background(Theme.Color.leaf.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish personalizing care").font(.subheadline.weight(.semibold))
                    Text("Tell us where you keep \(current.displayName) for a tailored water, light, and feeding plan.")
                        .font(.caption).foregroundStyle(Theme.Color.textSecondary)
                }
            }
            Button("Personalize care") { showPersonalize = true }
                .buttonStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
    }

    /// Only rendered when it has at least one row — with a care plan present and a
    /// pet-safe plant there's nothing generic left to say, and an empty card is
    /// worse than none.
    private var hasFacts: Bool {
        current.toxicityLevel?.isConcerning == true
            || (current.carePlan == nil
                && (current.lightingNeeds?.isEmpty == false
                    || current.fertilizerInfo?.isEmpty == false))
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
            // The generic identify-time light/fertilizer notes only until a real
            // care plan exists — the plan's Light and Nutrients cards supersede
            // them, and repeating both reads like two apps disagreeing.
            if current.carePlan == nil {
                if let light = current.lightingNeeds, !light.isEmpty {
                    factRow(icon: "sun.max.fill", label: "Light", value: light)
                }
                if let fert = current.fertilizerInfo, !fert.isEmpty {
                    factRow(icon: "leaf.fill", label: "Fertilizer", value: fert)
                }
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
