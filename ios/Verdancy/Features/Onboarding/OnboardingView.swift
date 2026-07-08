import SwiftUI

/// Light onboarding (iOS-PRD §8.1): 2–3 promise screens, then Sign in with Apple.
/// No permission prompts front-loaded.
/// The one-question personalization quiz (iOS-PRD §8.1: "keep any quiz short").
/// Pets at home → toxicity warnings speak to *their* home, not a generic one.
enum PetContext {
    private static let key = "verdancy.hasPets"

    static var hasPets: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The toxicity warning, personalized when we know pets are around.
    static var toxicityWarning: String {
        hasPets
            ? "Toxic to pets — keep it out of reach of curious paws"
            : "Toxic to pets and children if ingested"
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var isWorking = false
    @State private var error: String?
    @State private var petsAnswer: Bool?

    private let slides: [(icon: String, title: String, body: String)] = [
        ("camera.viewfinder", "Identify any plant", "Snap a photo and get a care card in seconds."),
        ("drop.fill", "Never overwater again", "Gentle reminders tuned to each plant you own."),
        ("tree.fill", "Grow a real forest", "Subscribe and we plant 10 real trees — plus one per milestone."),
    ]

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(slides.indices, id: \.self) { index in
                        VStack(spacing: Theme.Space.xl) {
                            IconBadge(systemImage: slides[index].icon, size: 128)
                            VStack(spacing: Theme.Space.m) {
                                Text(slides[index].title)
                                    .font(.largeTitle.weight(.bold))
                                    .multilineTextAlignment(.center)
                                Text(slides[index].body)
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(Theme.Color.textSecondary)
                            }
                            .padding(.horizontal, Theme.Space.xl)
                        }
                        .tag(index)
                    }

                    petsQuiz.tag(slides.count)
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: Theme.Space.m) {
                    AppleSignInButton(isWorking: isWorking) { await signIn() }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Theme.Color.danger)
                    }
                    Text("By continuing you agree to our Terms & Privacy Policy.")
                        .font(.caption2)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
            }
        }
        .onAppear { Analytics.log("onboarding_viewed") }
    }

    private var petsQuiz: some View {
        VStack(spacing: Theme.Space.xl) {
            IconBadge(systemImage: "pawprint.fill", size: 128, tint: Theme.Color.terracotta)
            VStack(spacing: Theme.Space.m) {
                Text("Any pets at home?")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("We'll flag any plant that isn't safe for curious paws.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            HStack(spacing: Theme.Space.m) {
                QuizChoice(label: "Yes, pets", icon: "pawprint.fill",
                           selected: petsAnswer == true) { answerPets(true) }
                QuizChoice(label: "No pets", icon: "house.fill",
                           selected: petsAnswer == false) { answerPets(false) }
            }
            .padding(.horizontal, Theme.Space.xl)
        }
    }

    private func answerPets(_ hasPets: Bool) {
        petsAnswer = hasPets
        PetContext.hasPets = hasPets
        Analytics.log("quiz_pets_answered", ["hasPets": String(hasPets)])
        Haptics.success()
    }

    private func signIn() async {
        isWorking = true
        error = nil
        Analytics.log("sign_in_started")
        do {
            try await app.signInWithApple()
            Analytics.log("sign_in_succeeded")
        } catch {
            self.error = "Sign in failed. Please try again."
            Analytics.log("sign_in_failed")
        }
        isWorking = false
    }
}

private struct QuizChoice: View {
    let label: String
    let icon: String
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.l)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(selected ? Theme.Color.leaf.opacity(0.15) : Theme.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(selected ? Theme.Color.leaf : Theme.Color.separator,
                                  lineWidth: selected ? 2 : 1)
            )
            .foregroundStyle(selected ? Theme.Color.leaf : Theme.Color.textPrimary)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// HIG-styled Sign in with Apple trigger. We federate via Amplify (hosted domain)
/// rather than the raw `ASAuthorizationController`, so this is a styled button.
struct AppleSignInButton: View {
    let isWorking: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "apple.logo")
                    Text("Sign in with Apple").fontWeight(.medium)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(Color.white)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .disabled(isWorking)
    }
}

#Preview {
    OnboardingView().environment(AppModel(auth: MockAuthService()))
}
