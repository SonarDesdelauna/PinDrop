import SwiftUI

@main
struct PinDropApp: App {
    @State private var authService: AuthService
    @State private var appState: AppState
    @State private var locationService: LocationService
    @State private var cameraService: CameraService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let location = LocationService()
        let client = Backend.client
        _authService = State(initialValue: AuthService(client: client))
        _locationService = State(initialValue: location)
        _cameraService = State(initialValue: CameraService())
        _appState = State(initialValue: AppState(dataService: SupabaseDataService(client: client), locationService: location))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authService)
                .environment(appState)
                .environment(locationService)
                .environment(cameraService)
                .preferredColorScheme(.light)
                .tint(Theme.neonPurple)
                .onOpenURL { url in
                    if AuthService.isAuthCallback(url) {
                        Task { _ = await authService.handleAuthCallback(url) }
                    } else {
                        appState.handleDeepLink(url)
                    }
                }
                .task {
                    authService.start()
                }
        }
        // iOS wakes the app now and then to look for new notifications.
        .backgroundTask(.appRefresh(PushNotifier.refreshTaskID)) { [push = appState.push] in
            await push.check()
            await push.scheduleBackgroundRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                appState.resetLocationBanners()
                Task { await appState.refresh() }
                if appState.sessionPhase == .ready {
                    appState.push.startPolling()
                }
            case .background:
                appState.pruneExpiredPins()
                appState.goOffline()
                appState.push.stopPolling()
                appState.push.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}

/// Routes between onboarding, authentication, profile setup and the main map.
struct RootView: View {
    @AppStorage("pindrop.onboarding.completed") private var hasCompletedOnboarding = false
    @Environment(AuthService.self) private var authService
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var auth = authService

        ZStack {
            Theme.obsidian.ignoresSafeArea()
            if !hasCompletedOnboarding {
                OnboardingView {
                    withAnimation(Theme.spring) {
                        hasCompletedOnboarding = true
                    }
                }
                .transition(.opacity)
            } else {
                switch authService.state {
                case .loading:
                    SplashView()
                        .transition(.opacity)
                case .signedOut:
                    AuthView()
                        .transition(.opacity)
                case .signedIn(let userID):
                    SessionView(userID: userID)
                        .transition(.opacity)
                }
            }
        }
        .animation(Theme.spring, value: authService.state)
        .onChange(of: authService.state) { _, state in
            if state == .signedOut {
                appState.reset()
            }
        }
        .sheet(isPresented: $auth.isPasswordRecoveryActive) {
            NewPasswordView()
                .presentationDetents([.medium])
        }
        // The profile color is the accent of the whole app: rebuild everything when it changes.
        .tint(Theme.neonPurple)
        .id(appState.accentHex)
    }
}

/// Content for a signed-in user: loading, error, profile setup or the map.
private struct SessionView: View {
    let userID: UUID
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.sessionPhase {
            case .idle, .loading:
                SplashView(message: "session.loading")
            case .failed(let message):
                SessionErrorView(message: message)
            case .ready:
                if appState.needsProfileSetup {
                    EditProfileView(mode: .setup)
                        .transition(.opacity)
                } else {
                    MainMapView()
                        .transition(.opacity)
                }
            }
        }
        .animation(Theme.spring, value: appState.sessionPhase)
        .animation(Theme.spring, value: appState.needsProfileSetup)
        .task(id: userID) {
            await appState.start(userID: userID)
        }
    }
}

/// Branded loading screen.
struct SplashView: View {
    var message: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 18) {
            AppLogoView(size: 104)
                .glow(Theme.electricViolet, radius: 22)
                .pulsing()
            ProgressView()
                .tint(Theme.neonPurple)
            if let message {
                Text(message)
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.obsidian.ignoresSafeArea())
    }
}

private struct SessionErrorView: View {
    let message: String
    @Environment(AppState.self) private var appState
    @Environment(AuthService.self) private var authService

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.warning)
            Text("session.error.title")
                .font(Theme.text(.title2, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(verbatim: message)
                .font(Theme.text(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await appState.retryStart() }
            } label: {
                Text("session.error.retry")
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            Button {
                Task { await authService.signOut() }
            } label: {
                Text("auth.signOut")
                    .font(Theme.text(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.obsidian.ignoresSafeArea())
    }
}
