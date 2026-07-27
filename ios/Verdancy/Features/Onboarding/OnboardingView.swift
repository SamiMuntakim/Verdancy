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
    @State private var showEmail = false

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
                    AppleSignInButton(isWorking: isWorking) {
                        await signIn("apple") { try await app.signInWithApple() }
                    }
                    GoogleSignInButton(isWorking: isWorking) {
                        await signIn("google") { try await app.signInWithGoogle() }
                    }
                    Button("Continue with email") { showEmail = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .disabled(isWorking)
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
        .sheet(isPresented: $showEmail) {
            EmailAuthView().environment(app)
        }
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

    private func signIn(_ method: String, _ action: @escaping () async throws -> Void) async {
        isWorking = true
        error = nil
        Analytics.log("sign_in_started", ["method": method])
        do {
            try await action()
            Analytics.log("sign_in_succeeded", ["method": method])
        } catch {
            self.error = "Sign in failed. Please try again."
            Analytics.log("sign_in_failed", ["method": method])
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

/// HIG-styled Sign in with Apple trigger. Tapping it runs the native
/// `ASAuthorizationController` system sheet (see `NativeAppleAuthService`) — the
/// styling here matches Apple's button; the sheet itself is the system UI.
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

/// "Sign in with Google" trigger, styled to Google's Sign-In branding guidelines:
/// the official multi-color "G" mark (asset `GoogleLogo`, unmodified), the exact
/// neutral light/dark button colors, and the canonical label. Runs OAuth + PKCE in
/// an in-app browser (`GoogleSignInController`).
struct GoogleSignInButton: View {
    @Environment(\.colorScheme) private var scheme
    let isWorking: Bool
    let action: () async -> Void

    private var isDark: Bool { scheme == .dark }
    // Google's specified button colors.
    private var background: Color {
        isDark ? Color(red: 0.075, green: 0.075, blue: 0.078) : .white // #131314 / #FFFFFF
    }
    private var stroke: Color {
        isDark
            ? Color(red: 0.557, green: 0.569, blue: 0.561) // #8E918F
            : Color(red: 0.455, green: 0.467, blue: 0.459) // #747775
    }
    private var label: Color {
        isDark
            ? Color(red: 0.890, green: 0.890, blue: 0.890) // #E3E3E3
            : Color(red: 0.122, green: 0.122, blue: 0.122) // #1F1F1F
    }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 10) {
                Image("GoogleLogo")
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: 18, height: 18)
                Text("Sign in with Google").font(.system(size: 17, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(label)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
        }
        .disabled(isWorking)
    }
}

#Preview {
    OnboardingView().environment(AppModel(auth: MockAuthService()))
}
