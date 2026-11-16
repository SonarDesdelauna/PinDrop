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
    @State private var storyShot: CapturedShot?
    @State private var captureMode: CaptureMode = .pin
    // Video: hold the shutter to record, slide up to lock.
    @State private var isRecording = false
    @State private var isStartingVideo = false
    @State private var stopWhenStarted = false
    @State private var isLocked = false
    @State private var lockDrag: CGFloat = 0
    @State private var pressStart: Date?
    @State private var pressBeganWhileRecording = false
    @State private var holdTask: Task<Void, Never>?
    @State private var recordTask: Task<Void, Never>?
    @State private var recordProgress: Double = 0
    @State private var recordLocationTask: Task<GeoPoint?, Never>?
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
            await camera.prepareMicrophone()
        }
        .onAppear {
            if appState.social.prefersStoryCapture {
                captureMode = .story
                appState.social.prefersStoryCapture = false
            }
        }
        .onDisappear {
            recordTask?.cancel()
            if isRecording {
                Task { _ = await camera.stopRecording() }
            }
            camera.stop()
        }
        .fullScreenCover(item: $storyShot) { shot in
            StoryComposerView(
                shot: shot,
                onRetake: {
                    storyShot = nil
                },
                onPublished: {
                    storyShot = nil
                    appState.isCameraPresented = false
                }
            )
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
                CameraPreviewLayer(session: camera.session) { camera.attachPreview($0) }
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
            ZStack {
                modeSwitch
                    .opacity(isRecording ? 0 : 1)
                if isRecording {
                    recordingInfo
                        .transition(.opacity)
                }
            }
            .animation(Theme.spring, value: isRecording)
            HStack {
                VStack(spacing: 4) {
                    Image(systemName: captureMode == .story ? "circle.dashed" : "timer")
                        .font(.system(size: 20, weight: .semibold))
                    Text(captureMode == .story ? LocalizedStringKey("story.duration") : LocalizedStringKey("camera.sixHours"))
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
                .disabled(camera.status != .running || isProcessing || isStartingVideo)
                .frame(width: 72)
                .accessibilityLabel(Text("camera.flip"))
            }

            Text(isRecording ? LocalizedStringKey(isLocked ? "camera.video.lockedHint" : "camera.video.holdHint") : (captureMode == .story ? LocalizedStringKey("story.camera.hint") : LocalizedStringKey("camera.hint")))
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// PIN or STORY, like the modes of a camera app.
    private var modeSwitch: some View {
        HStack(spacing: 6) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                let isSelected = captureMode == mode
                Button {
                    guard captureMode != mode else { return }
                    HapticManager.shared.selection()
                    withAnimation(Theme.spring) { captureMode = mode }
                } label: {
                    Text(mode.title)
                        .font(Theme.rounded(.footnote, weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule().fill(Color.white)
                            }
                        }
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.1), in: Capsule())
    }

    /// Tap for a photo, hold for a video (max 10 s), slide up while holding to lock.
    private var shutterButton: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white, lineWidth: 5)
                .frame(width: 86, height: 86)
                .scaleEffect(isRecording ? 1.18 : 1)
            if isRecording {
                Circle()
                    .trim(from: 0, to: recordProgress)
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 101, height: 101)
            }
            if isRecording {
                RoundedRectangle(cornerRadius: isLocked ? 8 : 35, style: .continuous)
                    .fill(Theme.danger)
                    .frame(width: isLocked ? 34 : 62, height: isLocked ? 34 : 62)
            } else {
                Circle()
                    .fill(captureMode == .story ? AnyShapeStyle(StoryRingStyle.angular) : AnyShapeStyle(Theme.accentGradient))
                    .frame(width: 70, height: 70)
                    .scaleEffect(isProcessing ? 0.82 : 1)
                    .glow(Theme.electricViolet, radius: 14)
            }
            if isProcessing {
                ProgressView()
                    .tint(Color.white)
            }
        }
        .frame(width: 104, height: 104)
        .contentShape(Circle())
        .overlay(alignment: .top) {
            if isRecording && !isLocked {
                VStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(lockDrag < -40 ? 0.35 : 0.15), in: Circle())
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .offset(y: -64 + min(0, lockDrag) * 0.3)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Theme.spring, value: isRecording)
        .animation(Theme.spring, value: isLocked)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged(shutterChanged)
                .onEnded(shutterEnded)
        )
        .disabled(camera.status != .running || isProcessing)
        .accessibilityElement()
        .accessibilityLabel(Text("camera.shutter"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { capture() }
    }

    /// "● 0:04" while recording.
    private var recordingInfo: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.danger)
                .frame(width: 8, height: 8)
                .pulsing()
            Text(verbatim: String(format: "0:%02d", Int(recordProgress * VideoTools.maxDuration)))
                .font(Theme.rounded(.subheadline, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Color.white)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.4), in: Capsule())
    }

    private func shutterChanged(_ value: DragGesture.Value) {
        if pressStart == nil {
            pressStart = .now
            pressBeganWhileRecording = isRecording
            if !isRecording && !isStartingVideo {
                holdTask?.cancel()
                holdTask = Task {
                    try? await Task.sleep(for: .milliseconds(170))
                    guard !Task.isCancelled else { return }
                    await startVideo()
                }
            }
        }
        guard (isRecording || isStartingVideo), !isLocked, !pressBeganWhileRecording else { return }
        lockDrag = value.translation.height
        if value.translation.height < -70 {
            isLocked = true
            lockDrag = 0
            HapticManager.shared.success()
        }
    }

    private func shutterEnded(_ value: DragGesture.Value) {
        holdTask?.cancel()
        let duration = Date.now.timeIntervalSince(pressStart ?? .now)
        let beganWhileRecording = pressBeganWhileRecording
        pressStart = nil
        lockDrag = 0
        if isRecording {
            // Unlocked: releasing stops. Locked: a new tap on the shutter stops.
            if !isLocked || beganWhileRecording {
                Task { await stopVideo() }
            }
        } else if isStartingVideo {
            if !isLocked { stopWhenStarted = true }
        } else if duration < 0.17 {
            capture()
        }
    }

    private func startVideo() async {
        guard !isProcessing, !isRecording, camera.status == .running else { return }
        isStartingVideo = true
        stopWhenStarted = false
        HapticManager.shared.tap()
        let locationService = self.locationService
        recordLocationTask = Task { await locationService.currentLocation(maximumAge: 20, timeout: 2) }
        let started = await camera.startRecording()
        isStartingVideo = false
        guard started else {
            isLocked = false
            HapticManager.shared.error()
            return
        }
        isRecording = true
        recordProgress = 0
        let start = Date.now
        recordTask?.cancel()
        recordTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                let elapsed = Date.now.timeIntervalSince(start)
                recordProgress = min(1, elapsed / VideoTools.maxDuration)
                if elapsed >= VideoTools.maxDuration {
                    await stopVideo()
                    return
                }
            }
        }
        if stopWhenStarted {
            stopWhenStarted = false
            await stopVideo()
        }
    }

    private func stopVideo() async {
        guard isRecording else { return }
        recordTask?.cancel()
        recordTask = nil
        isRecording = false
        isLocked = false
        isProcessing = true
        HapticManager.shared.tap()
        let url = await camera.stopRecording()
        let location = await recordLocationTask?.value
        recordLocationTask = nil
        defer {
            isProcessing = false
            recordProgress = 0
        }
        guard let url, await VideoTools.duration(of: url) >= 0.4 else {
            // Too short: treat it as nothing.
            return
        }
        guard let poster = await VideoTools.posterJPEG(for: url) else {
            errorMessage = CameraError.captureFailed.localizedDescription
            return
        }
        let processed = await Task.detached(priority: .userInitiated) {
            ImageCompressor.process(poster)
        }.value
        guard let processed, let preview = UIImage(data: processed.fullData) else {
            errorMessage = CameraError.captureFailed.localizedDescription
            return
        }
        var shot = CapturedShot(previewImage: preview, processed: processed, location: location, capturedAt: .now)
        shot.videoURL = url
        if captureMode == .story {
            storyShot = shot
        } else {
            capturedShot = shot
        }
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
                let shot = CapturedShot(
                    previewImage: preview,
                    processed: processed,
                    location: location,
                    capturedAt: .now
                )
                if captureMode == .story {
                    storyShot = shot
                } else {
                    capturedShot = shot
                }
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

/// What the shutter makes: a 6 h pin on the map or a 24 h story.
enum CaptureMode: CaseIterable, Hashable {
    case pin
    case story

    var title: LocalizedStringKey {
        switch self {
        case .pin: "camera.mode.pin"
        case .story: "camera.mode.story"
        }
    }
}
