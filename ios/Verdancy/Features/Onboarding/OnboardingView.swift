import SwiftUI

/// Dedicated onboarding flow (iOS-PRD §8.1): 3 promise screens → a short
/// personalization quiz → pets → **sign-up only on the final screen**. It's a
/// linear, Continue-driven funnel — the auth buttons never appear before the end, so
/// nobody can sign up mid-quiz and skip the flow. No permission prompts front-loaded;
/// the first scan (and its seedling payoff) comes *after* sign-up in `FirstRunView`.
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

/// The quiz answers we keep locally for personalization (iOS-PRD §8.1: "keep any
/// quiz short"). Coarse enum-like values only — no free text — mirroring the
/// Analytics privacy rule. Backed by UserDefaults; read anywhere in the app.
enum OnboardingProfile {
    /// Attribution — where the user first heard about us.
    static var source: String? {
        get { UserDefaults.standard.string(forKey: "verdancy.onboarding.source") }
        set { UserDefaults.standard.set(newValue, forKey: "verdancy.onboarding.source") }
    }

    /// Coarse bucket for how many plants the user keeps.
    static var plantCount: String? {
        get { UserDefaults.standard.string(forKey: "verdancy.onboarding.plantCount") }
        set { UserDefaults.standard.set(newValue, forKey: "verdancy.onboarding.plantCount") }
    }

    /// Self-reported experience level — tunes copy tone later on.
    static var experience: String? {
        get { UserDefaults.standard.string(forKey: "verdancy.onboarding.experience") }
        set { UserDefaults.standard.set(newValue, forKey: "verdancy.onboarding.experience") }
    }
}

/// One selectable choice inside a quiz question.
private struct QuizOption: Identifiable {
    let value: String
    let label: String
    let icon: String
    var id: String { value }
}

/// A single-select quiz question rendered as a page in onboarding.
private struct QuizQuestion: Identifiable {
    let id: String        // analytics/storage key, e.g. "source"
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let options: [QuizOption]
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var forward = true
    @State private var isWorking = false
    @State private var error: String?
    @State private var petsAnswer: Bool?
    @State private var showEmail = false

    /// Selected value per quiz question, keyed by `QuizQuestion.id`.
    @State private var answers: [String: String] = [:]

    private let slides: [(icon: String, title: String, body: String)] = [
        ("camera.viewfinder", "Know every plant you meet",
         "Point your camera at any plant — get its name, whether it's pet-safe, and how to keep it thriving in seconds."),
        ("drop.fill", "Never kill a plant again",
         "Care reminders tuned to each plant you own, so you water at the right time — never too much, never too late."),
        ("tree.fill", "You grow plants.\nWe grow forests.",
         "This isn't just another plant app. Subscribe and we plant 10 real trees with One Tree Planted — plus one more for every milestone — tracked on a public counter."),
    ]

    /// The short quiz (iOS-PRD §8.1). Pets is a separate final page below.
    private let questions: [QuizQuestion] = [
        QuizQuestion(
            id: "source",
            icon: "sparkle.magnifyingglass",
            tint: Theme.Color.leaf,
            title: "Where did you find us?",
            subtitle: "Helps us reach more plant lovers like you.",
            options: [
                QuizOption(value: "social", label: "Social media", icon: "bubble.left.and.bubble.right.fill"),
                QuizOption(value: "app_store", label: "App Store search", icon: "magnifyingglass"),
                QuizOption(value: "friend", label: "Friend or family", icon: "heart.fill"),
                QuizOption(value: "web", label: "Web search or article", icon: "safari.fill"),
                QuizOption(value: "other", label: "Somewhere else", icon: "ellipsis"),
            ]
        ),
        QuizQuestion(
            id: "plantCount",
            icon: "leaf.fill",
            tint: Theme.Color.leaf,
            title: "How many plants do you have?",
            subtitle: "We'll shape your garden around your collection.",
            options: [
                QuizOption(value: "none", label: "No plants yet", icon: "sparkles"),
                QuizOption(value: "1_5", label: "1 to 5", icon: "leaf"),
                QuizOption(value: "6_10", label: "6 to 10", icon: "leaf.fill"),
                QuizOption(value: "11_25", label: "11 to 25", icon: "tree"),
                QuizOption(value: "25_plus", label: "More than 25", icon: "tree.fill"),
            ]
        ),
        QuizQuestion(
            id: "experience",
            icon: "chart.line.uptrend.xyaxis",
            tint: Theme.Color.terracotta,
            title: "How experienced are you with plants?",
            subtitle: "So we can pitch our tips at the right level.",
            options: [
                QuizOption(value: "new", label: "Brand new", icon: "sparkles"),
                QuizOption(value: "some", label: "Some experience", icon: "leaf.fill"),
                QuizOption(value: "expert", label: "Very experienced", icon: "crown.fill"),
            ]
        ),
    ]

    /// Total steps: promise slides + quiz questions + pets + the final sign-up page.
    private var totalPages: Int { slides.count + questions.count + 2 }
    private var petsPage: Int { totalPages - 2 }
    private var authPage: Int { totalPages - 1 }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: false) {
                    currentPage
                        .id(page)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.top, Theme.Space.xl)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .frame(maxHeight: .infinity)

                footer
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xl)
            }
        }
        .onAppear { Analytics.log("onboarding_viewed") }
        .sheet(isPresented: $showEmail) {
            EmailAuthView().environment(app)
        }
    }

    // MARK: Chrome (progress + back)

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.Color.surface, in: Circle())
            }
            .opacity(page == 0 ? 0 : 1)
            .disabled(page == 0)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Color.separator)
                    Capsule()
                        .fill(Theme.leafGradient)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 6)

            // Balance the back button so the bar stays centered.
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.m)
        .animation(.easeOut(duration: 0.2), value: page)
    }

    private var progress: CGFloat { CGFloat(page + 1) / CGFloat(totalPages) }

    // MARK: Pages

    @ViewBuilder
    private var currentPage: some View {
        if page < slides.count {
            slideView(slides[page])
        } else if page < slides.count + questions.count {
            questionPage(questions[page - slides.count])
        } else if page == petsPage {
            petsQuiz
        } else {
            authHero
        }
    }

    private func slideView(_ slide: (icon: String, title: String, body: String)) -> some View {
        VStack(spacing: Theme.Space.xl) {
            IconBadge(systemImage: slide.icon, size: 128)
            VStack(spacing: Theme.Space.m) {
                Text(slide.title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(slide.body)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .padding(.top, Theme.Space.xxl)
    }

    /// A single-select quiz question: a hero badge, title, subtitle, then a vertical
    /// list of option rows. Tapping an option records it and advances.
    private func questionPage(_ question: QuizQuestion) -> some View {
        VStack(spacing: Theme.Space.xl) {
            IconBadge(systemImage: question.icon, size: 96, tint: question.tint)
            VStack(spacing: Theme.Space.s) {
                Text(question.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(question.subtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            VStack(spacing: Theme.Space.s) {
                ForEach(question.options) { option in
                    OptionRow(
                        label: option.label,
                        icon: option.icon,
                        selected: answers[question.id] == option.value
                    ) {
                        answer(question, option)
                    }
                }
            }
        }
    }

    private func answer(_ question: QuizQuestion, _ option: QuizOption) {
        answers[question.id] = option.value
        switch question.id {
        case "source": OnboardingProfile.source = option.value
        case "plantCount": OnboardingProfile.plantCount = option.value
        case "experience": OnboardingProfile.experience = option.value
        default: break
        }
        Analytics.log("quiz_answered", ["question": question.id, "answer": option.value])
        Haptics.success()
        // Gently advance so the quiz feels like a flow, not a form.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { goNext() }
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
        }
    }

    private func answerPets(_ hasPets: Bool) {
        petsAnswer = hasPets
        PetContext.hasPets = hasPets
        Analytics.log("quiz_answered", ["question": "pets", "answer": hasPets ? "yes" : "no"])
        Haptics.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { goNext() }
    }

    /// The final page: the *only* place auth appears. Hero here; buttons in `footer`.
    private var authHero: some View {
        VStack(spacing: Theme.Space.xl) {
            IconBadge(systemImage: "leaf.fill", size: 128)
            VStack(spacing: Theme.Space.m) {
                Text("Create your free account")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Save your garden and pick up where you left off on any device. Next, you'll scan your first plant.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .padding(.top, Theme.Space.xxl)
    }

    // MARK: Footer (Continue for slides, auth on the final page)

    @ViewBuilder
    private var footer: some View {
        if page < slides.count {
            Button("Continue") { goNext() }
                .buttonStyle(.primary)
        } else if page == authPage {
            authButtons
        }
        // Quiz + pets pages advance on tap — no footer button.
    }

    private var authButtons: some View {
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
            Text("No credit card to sign up. By continuing you agree to our Terms & Privacy Policy.")
                .font(.caption2)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Navigation

    private func goNext() {
        guard page < authPage else { return }
        forward = true
        withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
    }

    private func goBack() {
        guard page > 0 else { return }
        forward = false
        withAnimation(.easeInOut(duration: 0.28)) { page -= 1 }
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

/// A full-width, single-line selectable row for multi-option quiz questions:
/// leading glyph, label, and a checkmark once chosen.
private struct OptionRow: View {
    let label: String
    let icon: String
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 24)
                    .foregroundStyle(selected ? Theme.Color.leaf : Theme.Color.textSecondary)
                Text(label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.leaf)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(selected ? Theme.Color.leaf.opacity(0.15) : Theme.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(selected ? Theme.Color.leaf : Theme.Color.separator,
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
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
