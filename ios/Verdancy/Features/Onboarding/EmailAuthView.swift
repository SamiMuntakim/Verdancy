import SwiftUI

/// Minimal email/password sign-in/up in one sheet. Steps: credentials → (verify
/// code) for sign-up or unverified sign-in, and a forgot-password path. Verification
/// and reset codes are emailed by Cognito's built-in email. On success the session
/// is stored and `AppModel.phase` flips to signed-in, so we just dismiss.
struct EmailAuthView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Step { case credentials, confirmCode, forgotRequest, forgotReset }

    @State private var step: Step = .credentials
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var info: String?

    private let passwordHint =
        "At least 12 characters, with an uppercase, lowercase, number, and symbol."

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .credentials: credentialsSection
                case .confirmCode: confirmSection
                case .forgotRequest: forgotRequestSection
                case .forgotReset: forgotResetSection
                }
                if let info {
                    Text(info).font(.footnote).foregroundStyle(Theme.Color.textSecondary)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.Color.danger)
                }
            }
            .navigationTitle("Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(isWorking)
            .overlay {
                if isWorking { ProgressView().controlSize(.large) }
            }
        }
    }

    // MARK: - Sections

    private var credentialsSection: some View {
        Group {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(isSignUp ? .newPassword : .password)
            } footer: {
                if isSignUp { Text(passwordHint) }
            }

            Section {
                Button(isSignUp ? "Create account" : "Sign in") {
                    Task { await submitCredentials() }
                }
                .disabled(email.isEmpty || password.isEmpty)

                Button(isSignUp ? "Have an account? Sign in" : "New here? Create account") {
                    isSignUp.toggle()
                    error = nil
                    info = nil
                }
                .font(.footnote)

                if !isSignUp {
                    Button("Forgot password?") {
                        error = nil
                        info = nil
                        step = .forgotRequest
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var confirmSection: some View {
        Section {
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("Verify") { Task { await verifyCode() } }
                .disabled(code.isEmpty)
            Button("Resend code") { Task { await resendCode() } }
                .font(.footnote)
        } header: {
            Text("Enter the code we emailed to \(email)")
        }
    }

    private var forgotRequestSection: some View {
        Section {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send reset code") { Task { await sendResetCode() } }
                .disabled(email.isEmpty)
        } header: {
            Text("We'll email you a code to reset your password.")
        }
    }

    private var forgotResetSection: some View {
        Section {
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            SecureField("New password", text: $newPassword)
                .textContentType(.newPassword)
            Button("Reset & sign in") { Task { await resetPassword() } }
                .disabled(code.isEmpty || newPassword.isEmpty)
        } footer: {
            Text(passwordHint)
        }
    }

    // MARK: - Actions

    private var cleanEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func submitCredentials() async {
        if isSignUp {
            await run {
                try await EmailAuth.signUp(email: cleanEmail, password: password)
                info = "We emailed you a 6-digit code."
                step = .confirmCode
            }
        } else {
            isWorking = true
            error = nil
            info = nil
            do {
                try await app.signInWithEmail(cleanEmail, password: password)
                dismiss()
            } catch EmailAuthError.needsConfirmation {
                try? await EmailAuth.resendCode(email: cleanEmail)
                info = "Please verify your email. We sent you a code."
                step = .confirmCode
            } catch EmailAuthError.message(let message) {
                error = message
            } catch {
                self.error = "Something went wrong. Please try again."
            }
            isWorking = false
        }
    }

    private func verifyCode() async {
        await run {
            try await EmailAuth.confirmSignUp(email: cleanEmail, code: code)
            try await app.signInWithEmail(cleanEmail, password: password)
            dismiss()
        }
    }

    private func resendCode() async {
        await run {
            try await EmailAuth.resendCode(email: cleanEmail)
            info = "Sent a new code."
        }
    }

    private func sendResetCode() async {
        await run {
            try await EmailAuth.forgotPassword(email: cleanEmail)
            info = "Enter the code and choose a new password."
            step = .forgotReset
        }
    }

    private func resetPassword() async {
        await run {
            try await EmailAuth.confirmForgotPassword(
                email: cleanEmail, code: code, newPassword: newPassword)
            try await app.signInWithEmail(cleanEmail, password: newPassword)
            dismiss()
        }
    }

    /// Run an async action with the shared working/error handling.
    private func run(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        error = nil
        info = nil
        do {
            try await work()
        } catch EmailAuthError.message(let message) {
            error = message
        } catch EmailAuthError.needsConfirmation {
            error = "Please verify your email first."
        } catch {
            self.error = "Something went wrong. Please try again."
        }
        isWorking = false
    }
}

#Preview {
    EmailAuthView().environment(AppModel(auth: MockAuthService()))
}
