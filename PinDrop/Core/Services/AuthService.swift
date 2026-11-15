import Foundation
import Observation
import Supabase

/// Email + password authentication backed by Supabase Auth.
@MainActor
@Observable
final class AuthService {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(UUID)
    }

    private(set) var state: State = .loading
    private(set) var email: String?
    /// Set when the user opened a password-reset link: the app asks for a new password.
    var isPasswordRecoveryActive = false

    private let client: SupabaseClient
    @ObservationIgnored private var listenTask: Task<Void, Never>?

    init(client: SupabaseClient) {
        self.client = client
    }

    /// Starts listening to session changes (initial session, sign-in, sign-out, refresh).
    func start() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            guard let changes = self?.client.auth.authStateChanges else { return }
            for await change in changes {
                guard let self else { return }
                self.apply(event: change.event, session: change.session)
            }
        }
    }

    private func apply(event: AuthChangeEvent, session: Session?) {
        if event == .passwordRecovery {
            isPasswordRecoveryActive = true
        }
        if let session {
            email = session.user.email
            state = .signedIn(session.user.id)
        } else {
            email = nil
            state = .signedOut
        }
    }

    // MARK: - Actions

    /// Creates an account. Returns `true` when the user must confirm the email first.
    func signUp(email: String, password: String) async throws -> Bool {
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            redirectTo: SupabaseConfig.authRedirectURL
        )
        return response.session == nil
    }

    func signIn(email: String, password: String) async throws {
        _ = try await client.auth.signIn(email: email, password: password)
    }

    func resendConfirmation(email: String) async throws {
        try await client.auth.resend(email: email, type: .signup, emailRedirectTo: SupabaseConfig.authRedirectURL)
    }

    func sendPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email, redirectTo: SupabaseConfig.authRedirectURL)
    }

    func updatePassword(_ password: String) async throws {
        _ = try await client.auth.update(user: UserAttributes(password: password))
        isPasswordRecoveryActive = false
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
        } catch {
            // The local session is cleared even if the network call fails.
            state = .signedOut
        }
    }

    /// Handles `pindrop://auth-callback…` links from confirmation / reset emails.
    func handleAuthCallback(_ url: URL) async -> Bool {
        do {
            _ = try await client.auth.session(from: url)
            return true
        } catch {
            return false
        }
    }

    static func isAuthCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "pindrop" && url.host()?.lowercased() == "auth-callback"
    }

    // MARK: - Errors

    /// A short, localized explanation for an authentication error.
    static func message(for error: any Error) -> String {
        if let authError = error as? AuthError {
            switch authError.errorCode.rawValue {
            case "invalid_credentials":
                return String(localized: "auth.error.invalidCredentials")
            case "email_not_confirmed":
                return String(localized: "auth.error.emailNotConfirmed")
            case "user_already_exists", "email_exists":
                return String(localized: "auth.error.userExists")
            case "weak_password":
                return String(localized: "auth.error.weakPassword")
            case "over_email_send_rate_limit", "over_request_rate_limit":
                return String(localized: "auth.error.rateLimited")
            case "email_address_invalid", "validation_failed":
                return String(localized: "auth.error.invalidEmail")
            default:
                break
            }
        }
        if error is URLError {
            return String(localized: "error.data.network")
        }
        return String(localized: "auth.error.generic")
    }

    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !trimmed.contains(" ")
    }
}
