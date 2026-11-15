import AVFoundation
import CoreLocation
import SwiftUI

/// Three-step onboarding with Camera and "When In Use" location permission requests.
struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(LocationService.self) private var locationService

    @State private var step = 0
    @State private var cameraStatus: AVAuthorizationStatus = .notDetermined
    @State private var isFinishing = false

    private let lastStep = 2

    private enum PermissionState {
        case pending
        case granted
        case denied
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 20) {
                topBar

                TabView(selection: $step) {
                    introPage(
                        symbol: "camera.aperture",
                        title: Text("onboarding.step1.title"),
                        message: Text("onboarding.step1.body")
                    )
                    .tag(0)

                    introPage(
                        symbol: "lock.open.fill",
                        title: Text("onboarding.step2.title"),
                        message: Text("onboarding.step2.body")
                    )
                    .tag(1)

                    permissionsPage
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(Theme.spring, value: step)

                pageIndicator

                primaryButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .onAppear {
            cameraStatus = CameraService.authorizationStatus
        }
        .onChange(of: step) { _, _ in
            HapticManager.shared.selection()
        }
    }

    // MARK: - Chrome

    private var background: some View {
        ZStack {
            Theme.obsidian
            RadialGradient(
                colors: [Theme.electricViolet.opacity(0.45), Theme.obsidian.opacity(0)],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            RadialGradient(
                colors: [Theme.emerald.opacity(0.18), Theme.obsidian.opacity(0)],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Theme.accentGradient)
                Text(verbatim: "PinDrop")
                    .foregroundStyle(Theme.textPrimary)
            }
            .font(Theme.rounded(.title3, weight: .heavy))
            Spacer(minLength: 8)
            if step < lastStep {
                Button {
                    withAnimation(Theme.spring) {
                        step = lastStep
                    }
                } label: {
                    Text("onboarding.skip")
                        .font(Theme.text(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0...lastStep, id: \.self) { index in
                Capsule()
                    .fill(index == step ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.2)))
                    .frame(width: index == step ? 26 : 8, height: 8)
            }
        }
        .animation(Theme.spring, value: step)
        .accessibilityHidden(true)
    }

    private var primaryButton: some View {
        Button {
            if step < lastStep {
                withAnimation(Theme.spring) {
                    step += 1
                }
            } else {
                finish()
            }
        } label: {
            HStack(spacing: 8) {
                if isFinishing {
                    ProgressView()
                        .tint(Color.white)
                }
                if step < lastStep {
                    Text("onboarding.continue")
                } else {
                    Text("onboarding.start")
                }
            }
        }
        .buttonStyle(PrimaryGradientButtonStyle())
        .disabled(isFinishing)
    }

    // MARK: - Pages

    private func hero(symbol: String, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Theme.accentGradient)
                .frame(width: size * 1.1, height: size * 1.1)
                .blur(radius: 50)
                .opacity(0.55)
            Circle()
                .fill(Theme.surface.opacity(0.8))
                .frame(width: size, height: size)
                .glassCircle()
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
                .symbolEffect(.pulse, options: .repeating)
        }
        .accessibilityHidden(true)
    }

    private func introPage(symbol: String, title: Text, message: Text) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                hero(symbol: symbol, size: 150)
                VStack(spacing: 14) {
                    title
                        .font(Theme.text(.largeTitle, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    message
                        .font(Theme.text(.body))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var permissionsPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero(symbol: "location.viewfinder", size: 110)
                    .padding(.top, 8)

                VStack(spacing: 10) {
                    Text("onboarding.step3.title")
                        .font(Theme.text(.title, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text("onboarding.step3.body")
                        .font(Theme.text(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    permissionRow(
                        icon: "camera.fill",
                        title: Text("onboarding.permission.camera.title"),
                        subtitle: Text("onboarding.permission.camera.subtitle"),
                        state: cameraPermissionState
                    ) {
                        requestCamera()
                    }
                    permissionRow(
                        icon: "location.fill",
                        title: Text("onboarding.permission.location.title"),
                        subtitle: Text("onboarding.permission.location.subtitle"),
                        state: locationPermissionState
                    ) {
                        requestLocation()
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var cameraPermissionState: PermissionState {
        switch cameraStatus {
        case .authorized: .granted
        case .notDetermined: .pending
        default: .denied
        }
    }

    private var locationPermissionState: PermissionState {
        if locationService.isAuthorized { return .granted }
        if locationService.authorizationStatus == .notDetermined { return .pending }
        return .denied
    }

    private func permissionRow(
        icon: String,
        title: Text,
        subtitle: Text,
        state: PermissionState,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.accentGradient))
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                subtitle
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            switch state {
            case .granted:
                Label {
                    Text("onboarding.permission.granted")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.emerald)
                .transition(.scale.combined(with: .opacity))
            case .pending:
                Button(action: action) {
                    Text("onboarding.permission.allow")
                        .font(Theme.rounded(.footnote, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.accentGradient))
                }
                .buttonStyle(PressableButtonStyle())
            case .denied:
                Button {
                    SystemSettings.openAppSettings()
                } label: {
                    Text("onboarding.permission.openSettings")
                        .font(Theme.rounded(.footnote, weight: .bold))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.warning.opacity(0.15)))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(14)
        .glassCard(cornerRadius: Theme.Radius.control)
        .animation(Theme.spring, value: state)
    }

    // MARK: - Actions

    private func requestCamera() {
        HapticManager.shared.tap()
        Task {
            _ = await CameraService.requestAccess()
            withAnimation(Theme.spring) {
                cameraStatus = CameraService.authorizationStatus
            }
        }
    }

    private func requestLocation() {
        HapticManager.shared.tap()
        Task {
            await locationService.requestAuthorization()
        }
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        HapticManager.shared.success()
        isFinishing = false
        onFinish()
    }
}
