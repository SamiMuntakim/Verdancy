import SwiftUI

/// Light onboarding (iOS-PRD §8.1): 2–3 promise screens, then Sign in with Apple.
/// No permission prompts front-loaded.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var isWorking = false
    @State private var error: String?

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
    }

    private func signIn() async {
        isWorking = true
        error = nil
        do {
            try await app.signInWithApple()
        } catch {
            self.error = "Sign in failed. Please try again."
        }
        isWorking = false
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
