import SwiftUI

/// Email + password sign-in / sign-up, email confirmation and password reset.
struct AuthView: View {
    private enum Mode {
        case signIn
        case signUp
    }

    private enum Field {
        case email
        case password
    }

    static let minimumPasswordLength = 8

    @Environment(AuthService.self) private var authService

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pendingConfirmationEmail: String?
    @FocusState private var focusedField: Field?

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canSubmit: Bool {
        !isWorking && AuthService.isValidEmail(trimmedEmail) && password.count >= (mode == .signUp ? Self.minimumPasswordLength : 1)
    }

    var body: some View {
        ZStack {
            background
            if let pendingConfirmationEmail {
                confirmationView(email: pendingConfirmationEmail)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                formView
                    .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: pendingConfirmationEmail)
        .animation(Theme.spring, value: mode)
        .animation(Theme.spring, value: errorMessage)
        .animation(Theme.spring, value: infoMessage)
    }

    // MARK: - Layout

    private var background: some View {
        ZStack {
            Theme.obsidian
            RadialGradient(
                colors: [Theme.electricViolet.opacity(0.45), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [Theme.emerald.opacity(0.22), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }

    private var formView: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 92, height: 92)
                        .glassCircle()
                        .glow(Theme.neonPurple, radius: 24)
                    Text(mode == .signIn ? "auth.signIn.title" : "auth.signUp.title")
                        .font(Theme.text(.largeTitle, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text(mode == .signIn ? "auth.signIn.subtitle" : "auth.signUp.subtitle")
                        .font(Theme.text(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                modePicker

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(Theme.neonPurple)
                            .frame(width: 22)
                        TextField("auth.email.placeholder", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .email)
                            .onSubmit { focusedField = .password }
                    }
                    .authField()

                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Theme.neonPurple)
                            .frame(width: 22)
                        Group {
                            if isPasswordVisible {
                                TextField("auth.password.placeholder", text: $password)
                            } else {
                                SecureField("auth.password.placeholder", text: $password)
                            }
                        }
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { submit() }
                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel(Text("auth.password.toggle"))
                    }
                    .authField()

                    if mode == .signUp {
                        Text("auth.password.rules \(Self.minimumPasswordLength)")
                            .font(Theme.text(.caption))
                            .foregroundStyle(password.count >= Self.minimumPasswordLength || password.isEmpty ? Theme.textSecondary : Theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }

                messages

                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .tint(Color.white)
                        }
                        Text(mode == .signIn ? "auth.signIn.action" : "auth.signUp.action")
                    }
                }
                .buttonStyle(PrimaryGradientButtonStyle())
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.55)

                if mode == .signIn {
                    Button {
                        sendReset()
                    } label: {
                        Text("auth.forgotPassword")
                            .font(Theme.text(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.neonPurple)
                    }
                    .disabled(isWorking)
                }

                Text("auth.privacyNote")
                    .font(Theme.text(.caption2))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton(.signIn, title: "auth.tab.signIn")
            modeButton(.signUp, title: "auth.tab.signUp")
        }
        .padding(4)
        .glassCapsule()
    }

    private func modeButton(_ target: Mode, title: LocalizedStringKey) -> some View {
        Button {
            guard mode != target else { return }
            HapticManager.shared.selection()
            mode = target
            errorMessage = nil
            infoMessage = nil
        } label: {
            Text(title)
                .font(Theme.text(.subheadline, weight: .bold))
                .foregroundStyle(mode == target ? Color.white : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if mode == target {
                        Capsule().fill(Theme.accentGradient)
                    }
                }
        }
        .buttonStyle(PressableButtonStyle())
    }

    @ViewBuilder
    private var messages: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.text(.footnote, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
        if let infoMessage {
            Label(infoMessage, systemImage: "checkmark.circle.fill")
                .font(Theme.text(.footnote, weight: .semibold))
                .foregroundStyle(Theme.emerald)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }

    private func confirmationView(email: String) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 110, height: 110)
                .glassCircle()
                .glow(Theme.neonPurple, radius: 26)
            VStack(spacing: 10) {
                Text("auth.confirm.title")
                    .font(Theme.text(.title, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text("auth.confirm.body \(email)")
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            messages

            VStack(spacing: 12) {
                Button {
                    pendingConfirmationEmail = nil
                    mode = .signIn
                    errorMessage = nil
                    infoMessage = nil
                } label: {
                    Text("auth.confirm.done")
                }
                .buttonStyle(PrimaryGradientButtonStyle())

                Button {
                    resend(to: email)
                } label: {
                    Text("auth.confirm.resend")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(isWorking)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Actions

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        isWorking = true
        errorMessage = nil
        infoMessage = nil
        let email = trimmedEmail
        let password = password
        let mode = mode
        Task {
            do {
                switch mode {
                case .signIn:
                    try await authService.signIn(email: email, password: password)
                    HapticManager.shared.success()
                case .signUp:
                    let needsConfirmation = try await authService.signUp(email: email, password: password)
                    HapticManager.shared.success()
                    if needsConfirmation {
                        pendingConfirmationEmail = email
                    }
                }
            } catch {
                HapticManager.shared.error()
                errorMessage = AuthService.message(for: error)
            }
            isWorking = false
        }
    }

    private func sendReset() {
        guard AuthService.isValidEmail(trimmedEmail) else {
            errorMessage = String(localized: "auth.error.invalidEmail")
            focusedField = .email
            return
        }
        isWorking = true
        errorMessage = nil
        infoMessage = nil
        let email = trimmedEmail
        Task {
            do {
                try await authService.sendPasswordReset(email: email)
                infoMessage = String(localized: "auth.reset.sent")
            } catch {
                errorMessage = AuthService.message(for: error)
            }
            isWorking = false
        }
    }

    private func resend(to email: String) {
        isWorking = true
        errorMessage = nil
        infoMessage = nil
        Task {
            do {
                try await authService.resendConfirmation(email: email)
                infoMessage = String(localized: "auth.confirm.resent")
            } catch {
                errorMessage = AuthService.message(for: error)
            }
            isWorking = false
        }
    }
}

/// Sheet shown after opening a password-reset link.
struct NewPasswordView: View {
    @Environment(AuthService.self) private var authService
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("auth.newPassword.body")
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                SecureField("auth.password.placeholder", text: $password)
                    .textContentType(.newPassword)
                    .authField()
                Text("auth.password.rules \(AuthView.minimumPasswordLength)")
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(Theme.text(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                }
                Button {
                    save()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .tint(Color.white)
                        }
                        Text("profile.save")
                    }
                }
                .buttonStyle(PrimaryGradientButtonStyle())
                .disabled(password.count < AuthView.minimumPasswordLength || isWorking)
                Spacer()
            }
            .padding(24)
            .background(Theme.obsidian.ignoresSafeArea())
            .navigationTitle(Text("auth.newPassword.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        authService.isPasswordRecoveryActive = false
                    } label: {
                        Text("common.cancel")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await authService.updatePassword(password)
                HapticManager.shared.success()
            } catch {
                errorMessage = AuthService.message(for: error)
            }
            isWorking = false
        }
    }
}

private extension View {
    func authField() -> some View {
        self
            .font(Theme.text(.body, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .glassCard(cornerRadius: Theme.Radius.control)
    }
}
