import SwiftUI

/// Phase 1 sign-in. (Light onboarding screens — iOS-PRD §8.1 — land in Phase 4.)
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.xl) {
                Spacer()
                VStack(spacing: Theme.Space.m) {
                    Image(systemName: "leaf.circle.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(Theme.Color.leaf)
                    Text("Verdancy")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("Identify plants, keep them thriving,\nand plant real trees.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
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
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
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
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(Color.white)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .disabled(isWorking)
    }
}

#Preview {
    SignInView().environment(AppModel(auth: MockAuthService()))
}
