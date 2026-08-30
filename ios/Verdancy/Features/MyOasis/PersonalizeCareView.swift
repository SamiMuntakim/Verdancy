import SwiftUI

/// "Finish personalizing care" — a short, guided form over `Personalization`.
/// Generating the plan is a subscriber feature: non-subscribers are routed to the
/// paywall BEFORE any AI call, so no Gemini credits are spent on unpaid users.
/// The parent supplies the `NavigationStack`; this view does not nest one.
struct PersonalizeCareView: View {
    @Environment(AppModel.self) private var app

    let plant: Plant
    /// Called when the user finishes (plan created) or skips.
    var onFinished: () -> Void

    @State private var inputs = Personalization()
    @State private var phase: Phase = .form
    @State private var showPaywall = false
    @State private var error: String?
    /// Whether we've re-verified entitlement with RevenueCat since this gate opened.
    /// Guards against a stale local flag wrongly routing a real subscriber to the
    /// paywall (e.g. after a restore or a purchase made on another device).
    @State private var entitlementChecked = false

    private enum Phase: Equatable {
        case form, generating, result(CarePlan)
    }

    private var canGenerateForFree: Bool { app.isSubscribed || AppConfig.useMockAuth }

    var body: some View {
        content
            .navigationTitle("Personalize care")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPaywall) { PaywallView() }
            // Trust RevenueCat over the cached flag before gating: a subscriber whose
            // local `isSubscribed` is stale must reach the form, not the paywall.
            .task {
                if !canGenerateForFree { await app.entitlement.refresh() }
                entitlementChecked = true
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .form:
            // Free users can't generate a plan, so don't send them through a form
            // that dead-ends. Show what the plan looks like, locked, and offer it.
            if canGenerateForFree {
                formView
            } else if !entitlementChecked {
                // Briefly re-verifying entitlement; don't flash the paywall gate at a
                // subscriber whose cached flag just hasn't refreshed yet.
                entitlementCheckView
            } else {
                carePlanTeaser
            }
        case .generating:
            VStack(spacing: Theme.Space.m) {
                ProgressView().tint(Theme.Color.leaf)
                Text("Building \(plant.displayName)'s care plan…")
                    .font(.subheadline).foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.background)
        case let .result(plan):
            resultView(plan)
        }
    }

    /// Shown for the moment between opening the gate and confirming entitlement, so a
    /// subscriber with a stale cached flag never sees the paywall teaser flash by.
    private var entitlementCheckView: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressView().tint(Theme.Color.leaf)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.background)
    }

    // MARK: - Free teaser

    /// The care-plan gate as a value preview: a redacted plan card showing water,
    /// light, and feeding rows, so a free user sees the shape of what they'd unlock.
    private var carePlanTeaser: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                LockedPreviewCard(icon: "list.bullet.clipboard.fill",
                                  header: "\(plant.displayName)'s care plan") {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        teaserRow(icon: "drop.fill", title: "Water",
                                  value: "Every 9 days, less in winter")
                        teaserRow(icon: "sun.max.fill", title: "Light",
                                  value: "Bright, indirect — a few feet from a window")
                        teaserRow(icon: "leaf.fill", title: "Feed",
                                  value: "Monthly through spring and summer")
                    }
                }

                VStack(spacing: Theme.Space.xs) {
                    Text("Unlock \(plant.displayName)'s care plan")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Tailored to your pot, light, and home, with watering that errs on the safe side. Your plant keeps its ID and buddy on the free plan; the care plan is Premium.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                Button("Unlock care plan") {
                    Analytics.log("care_plan_gate_hit", ["gate": "teaser"])
                    showPaywall = true
                }
                .buttonStyle(.primary)

                Button("Skip for now") { onFinished() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.Color.background)
    }

    private func teaserRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 28, height: 28)
                .background(Theme.Color.leaf.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(value).font(.caption).foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Form

    private var formView: some View {
        Form {
            Section {
                Text("Tell us about \(plant.displayName)'s spot and we'll tailor its water, light, and feeding.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Section("Pot") {
                Picker("Pot size", selection: $inputs.potSize) {
                    ForEach(Personalization.PotSize.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Has a drainage hole", isOn: $inputs.hasDrainage)
                Picker("Soil", selection: $inputs.soilType) {
                    ForEach(Personalization.SoilType.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Light") {
                Picker("Location", selection: $inputs.indoor) {
                    Text("Indoor").tag(true)
                    Text("Outdoor").tag(false)
                }
                Toggle("Gets direct sunlight", isOn: $inputs.directSunlight)
                if inputs.directSunlight {
                    Stepper("Direct sun: \(inputs.directSunlightHours) hr/day",
                            value: $inputs.directSunlightHours, in: 0...16)
                }
                Picker("Nearest window", selection: $inputs.windowOrientation) {
                    Text("Not sure").tag(Personalization.WindowOrientation?.none)
                    ForEach(Personalization.WindowOrientation.allCases) {
                        Text("\($0.rawValue)-facing").tag(Optional($0))
                    }
                }
                Picker("Distance from window", selection: $inputs.distanceFromWindow) {
                    ForEach(Personalization.WindowDistance.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Uses a grow light", isOn: $inputs.growLight)
            }

            if let error {
                Section { Text(error).foregroundStyle(Theme.Color.danger) }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var bottomBar: some View {
        VStack(spacing: Theme.Space.s) {
            Button {
                Task { await generate() }
            } label: {
                Label("Create care plan", systemImage: "sparkles")
            }
            .buttonStyle(.primary)

            Button("Skip for now") { onFinished() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(Theme.Space.l)
        .background(.bar)
    }

    // MARK: - Result

    private func resultView(_ plan: CarePlan) -> some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                VStack(spacing: Theme.Space.xs) {
                    IconBadge(systemImage: "checkmark.seal.fill")
                    Text("\(plant.displayName)'s care plan is ready")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Tailored to where you keep it.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                CarePlanView(plan: plan)
                Button("Done") { onFinished() }
                    .buttonStyle(.primary)
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.Color.background)
    }

    // MARK: - Generate

    private func generate() async {
        error = nil
        // Gate before any network/credits (the server independently returns 402).
        if !canGenerateForFree {
            Analytics.log("care_plan_gate_hit", ["gate": "paywall"])
            showPaywall = true
            return
        }
        Analytics.log("care_plan_started", [:])
        phase = .generating
        do {
            if AppConfig.useMockAuth {
                try? await Task.sleep(for: .seconds(1))
                app.garden.update(plant.withCarePlan(.sample))
                phase = .result(.sample)
            } else {
                let updated = try await app.api.generateCarePlan(plantId: plant.plantId, inputs)
                app.garden.update(updated)
                phase = .result(updated.carePlan ?? .sample)
            }
            Haptics.success()
            Analytics.log("care_plan_created", [:])
        } catch APIError.paywall {
            phase = .form
            Analytics.log("care_plan_gate_hit", ["gate": "paywall"])
            showPaywall = true
        } catch APIError.rateLimited {
            phase = .form
            error = "You've generated a lot today. Try again tomorrow."
        } catch {
            phase = .form
            self.error = (error as? APIError)?.userMessage ?? "Couldn't create the plan. Try again."
        }
    }
}

#Preview {
    NavigationStack {
        PersonalizeCareView(plant: .sampleSnake) {}
            .environment(AppModel(auth: MockAuthService(startSignedIn: true)))
    }
}
