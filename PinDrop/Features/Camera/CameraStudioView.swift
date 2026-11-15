import AVFoundation
import SwiftUI

/// Full-screen live camera. No photo library, no filters, no AI: what you see is what you drop.
/// The GPS position is read only at the instant the shutter is pressed.
struct CameraStudioView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(CameraService.self) private var camera
    @Environment(LocationService.self) private var locationService

    @State private var capturedShot: CapturedShot?
    @State private var isProcessing = false
    @State private var flashOverlayOpacity: Double = 0
    @State private var errorMessage: String?
    @State private var pinchBaseZoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                topBar
                viewfinder
                zoomSelector
                Spacer(minLength: 0)
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Color.white
                .opacity(flashOverlayOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            await camera.start()
            if locationService.authorizationStatus == .notDetermined {
                await locationService.requestAuthorization()
            }
        }
        .onDisappear {
            camera.stop()
        }
        .sheet(item: $capturedShot) { shot in
            PostCaptureSheet(
                shot: shot,
                onRetake: {
                    capturedShot = nil
                },
                onDropped: {
                    capturedShot = nil
                    appState.isCameraPresented = false
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.obsidian)
            .presentationCornerRadius(Theme.Radius.sheet)
            .interactiveDismissDisabled()
        }
        .alert(
            Text("camera.error.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented { errorMessage = nil }
                }
            )
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                HapticManager.shared.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleGlassButtonStyle())
            .accessibilityLabel(Text("common.close"))

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.emerald)
                    .frame(width: 8, height: 8)
                    .pulsing()
                Text("camera.live")
                    .font(Theme.rounded(.footnote, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassCapsule()

            Spacer(minLength: 8)

            Button {
                HapticManager.shared.selection()
                camera.cycleFlash()
            } label: {
                Image(systemName: flashIconName)
                    .foregroundStyle(camera.flashMode == .off ? Theme.textPrimary : Color.yellow)
            }
            .buttonStyle(CircleGlassButtonStyle())
            .disabled(!camera.isFlashAvailable)
            .accessibilityLabel(Text("camera.flash"))
        }
    }

    private var flashIconName: String {
        switch camera.flashMode {
        case .on: "bolt.fill"
        case .auto: "bolt.badge.automatic.fill"
        default: "bolt.slash.fill"
        }
    }

    // MARK: - Viewfinder (3:4)

    private var viewfinder: some View {
        ZStack {
            switch camera.status {
            case .unauthorized:
                permissionPlaceholder
            case .failed(let message):
                failurePlaceholder(message: message)
            default:
                CameraPreviewLayer(session: camera.session)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                camera.setZoom(pinchBaseZoom * value.magnification, animated: false)
                            }
                            .onEnded { _ in
                                pinchBaseZoom = camera.zoomFactor
                            }
                    )
                if camera.status == .configuring || camera.status == .idle {
                    ProgressView()
                        .tint(Color.white)
                        .controlSize(.large)
                }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                Text("camera.gpsBadge")
            }
            .font(Theme.text(.caption, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassCapsule()
            .padding(12)
        }
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
            Text("camera.permission.title")
                .font(Theme.text(.title3, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("camera.permission.body")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
            Button {
                SystemSettings.openAppSettings()
            } label: {
                Text("common.openSettings")
            }
            .buttonStyle(PrimaryGradientButtonStyle(fullWidth: false))
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private func failurePlaceholder(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Theme.warning)
            Text(verbatim: message)
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
            Button {
                Task { await camera.start() }
            } label: {
                Text("common.retry")
            }
            .buttonStyle(GlassButtonStyle(fullWidth: false))
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    // MARK: - Zoom

    @ViewBuilder
    private var zoomSelector: some View {
        if camera.zoomPresets.count > 1 {
            HStack(spacing: 8) {
                ForEach(camera.zoomPresets, id: \.self) { preset in
                    let isSelected = abs(camera.zoomFactor - preset) < 0.25
                    Button {
                        HapticManager.shared.selection()
                        camera.setZoom(preset, animated: true)
                        pinchBaseZoom = preset
                    } label: {
                        Text("camera.zoom \(Int(preset))")
                            .font(Theme.rounded(.footnote, weight: .bold))
                            .foregroundStyle(isSelected ? Color.yellow : Theme.textPrimary)
                            .frame(minWidth: 40, minHeight: 34)
                            .background(Circle().fill(Color.white.opacity(isSelected ? 0.16 : 0.06)))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(4)
            .glassCapsule()
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .semibold))
                    Text("camera.sixHours")
                        .font(Theme.rounded(.caption2, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72)
                .accessibilityElement(children: .combine)

                Spacer(minLength: 8)

                shutterButton

                Spacer(minLength: 8)

                Button {
                    flip()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                }
                .buttonStyle(CircleGlassButtonStyle(diameter: 56))
                .disabled(camera.status != .running || isProcessing)
                .frame(width: 72)
                .accessibilityLabel(Text("camera.flip"))
            }

            Text("camera.hint")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shutterButton: some View {
        Button {
            capture()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 5)
                    .frame(width: 86, height: 86)
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 70, height: 70)
                    .scaleEffect(isProcessing ? 0.82 : 1)
                    .glow(Theme.electricViolet, radius: 14)
                if isProcessing {
                    ProgressView()
                        .tint(Color.white)
                }
            }
            .animation(Theme.spring, value: isProcessing)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
        .disabled(camera.status != .running || isProcessing)
        .accessibilityLabel(Text("camera.shutter"))
    }

    // MARK: - Actions

    private func flip() {
        HapticManager.shared.cameraFlip()
        Task {
            await camera.flipCamera()
            pinchBaseZoom = 1
        }
    }

    private func capture() {
        guard !isProcessing, camera.status == .running else { return }
        isProcessing = true
        HapticManager.shared.shutter()
        withAnimation(.easeOut(duration: 0.08)) {
            flashOverlayOpacity = 0.85
        }

        let camera = self.camera
        let locationService = self.locationService

        Task {
            // Photo and GPS fix are acquired together, at the very instant of the shot.
            async let photoData = camera.capturePhoto()
            async let locationFix = locationService.currentLocation(maximumAge: 20, timeout: 1.5)

            do {
                let rawData = try await photoData
                let location = await locationFix
                let processed = await Task.detached(priority: .userInitiated) {
                    ImageCompressor.process(rawData)
                }.value
                guard let processed, let preview = UIImage(data: processed.fullData) else {
                    throw CameraError.captureFailed
                }
                capturedShot = CapturedShot(
                    previewImage: preview,
                    processed: processed,
                    location: location,
                    capturedAt: .now
                )
            } catch {
                HapticManager.shared.error()
                errorMessage = error.localizedDescription
            }

            isProcessing = false
            withAnimation(.easeIn(duration: 0.3)) {
                flashOverlayOpacity = 0
            }
        }
    }
}
