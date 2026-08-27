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

    private enum Phase: Equatable {
        case form, generating, result(CarePlan)
    }

    private var canGenerateForFree: Bool { app.isSubscribed || AppConfig.useMockAuth }

    var body: some View {
        content
            .navigationTitle("Personalize care")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .form:
            formView
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
                Label(
                    canGenerateForFree ? "Create care plan" : "Create care plan",
                    systemImage: canGenerateForFree ? "sparkles" : "lock.fill"
                )
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
