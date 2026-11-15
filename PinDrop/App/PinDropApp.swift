import SwiftUI

@main
struct PinDropApp: App {
    @State private var appState: AppState
    @State private var locationService: LocationService
    @State private var cameraService: CameraService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let location = LocationService()
        // Swap `MockDataService` for a Supabase/Firebase implementation of `DataServiceProtocol`.
        let dataService: any DataServiceProtocol = MockDataService()
        _locationService = State(initialValue: location)
        _cameraService = State(initialValue: CameraService())
        _appState = State(initialValue: AppState(dataService: dataService, locationService: location))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(locationService)
                .environment(cameraService)
                .preferredColorScheme(.dark)
                .tint(Theme.neonPurple)
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
                .task {
                    await appState.bootstrap()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await appState.refresh() }
            case .background:
                appState.pruneExpiredPins()
            default:
                break
            }
        }
    }
}

/// Routes between onboarding and the main map.
struct RootView: View {
    @AppStorage("pindrop.onboarding.completed") private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            Theme.obsidian.ignoresSafeArea()
            if hasCompletedOnboarding {
                MainMapView()
                    .transition(.opacity)
            } else {
                OnboardingView {
                    withAnimation(Theme.spring) {
                        hasCompletedOnboarding = true
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
