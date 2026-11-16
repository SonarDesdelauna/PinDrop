import AVFoundation
import Observation
import UIKit

enum CameraError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case deviceUnavailable
    case configurationFailed
    case captureFailed
    case sessionNotRunning

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            String(localized: "camera.error.unauthorized")
        case .deviceUnavailable:
            String(localized: "camera.error.deviceUnavailable")
        case .configurationFailed:
            String(localized: "camera.error.configurationFailed")
        case .captureFailed:
            String(localized: "camera.error.captureFailed")
        case .sessionNotRunning:
            String(localized: "camera.error.sessionNotRunning")
        }
    }
}

struct CameraCapabilities: Sendable, Equatable {
    let position: AVCaptureDevice.Position
    let hasFlash: Bool
    let minZoom: CGFloat
    let maxZoom: CGFloat
}

// MARK: - Capture engine (session queue)

/// Owns the `AVCaptureSession`. Every mutable member is only touched on `queue`,
/// which is what makes the `@unchecked Sendable` conformance sound.
final class CaptureEngine: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Upper bound for zoom, to keep live photos sharp and honest.
    static let maximumZoom: CGFloat = 5

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.pindrop.camera.session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var microphoneInput: AVCaptureDeviceInput?
    /// Sample buffers and the recorder live on this queue only.
    private let recordQueue = DispatchQueue(label: "com.pindrop.camera.record", qos: .userInitiated)
    private var recorder: VideoRecorder?
    private var currentInput: AVCaptureDeviceInput?
    private var processors: [Int64: PhotoCaptureProcessor] = [:]
    private var isOutputConfigured = false

    /// Configures (or reconfigures) the session for the camera at `position`.
    func configure(position: AVCaptureDevice.Position) async throws -> CameraCapabilities {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let capabilities = try self.configureSession(position: position)
                    continuation.resume(returning: capabilities)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setZoom(_ factor: CGFloat, animated: Bool) {
        queue.async {
            guard let device = self.currentInput?.device else { return }
            let upperBound = min(device.maxAvailableVideoZoomFactor, Self.maximumZoom)
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), upperBound)
            guard (try? device.lockForConfiguration()) != nil else { return }
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 6)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        }
    }

    /// Captures a single still photo and returns its encoded file data (HEIC or JPEG).
    func capturePhoto(flashMode: AVCaptureDevice.FlashMode) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning else {
                    continuation.resume(throwing: CameraError.sessionNotRunning)
                    return
                }
                let settings = AVCapturePhotoSettings()
                if self.photoOutput.supportedFlashModes.contains(flashMode) {
                    settings.flashMode = flashMode
                }
                settings.photoQualityPrioritization = .balanced
                // Re-apply portrait rotation right before every shot: the connection can be
                // recreated by the session after reconfiguration, losing the angle.
                self.configurePhotoConnection(position: self.currentInput?.device.position ?? .back)
                let identifier = settings.uniqueID
                let processor = PhotoCaptureProcessor(continuation: continuation) {
                    self.queue.async {
                        self.processors[identifier] = nil
                    }
                }
                self.processors[identifier] = processor
                self.photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }

    // MARK: Private (queue only)

    private func configureSession(position: AVCaptureDevice.Position) throws -> CameraCapabilities {
        guard let device = Self.device(for: position) else { throw CameraError.deviceUnavailable }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.configurationFailed
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if !isOutputConfigured {
            session.sessionPreset = .photo
            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
            session.addOutput(photoOutput)
            // Frames for videos: preview sized, enough for a 720 x 960 clip.
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.deliversPreviewSizedOutputBuffers = true
            videoOutput.setSampleBufferDelegate(self, queue: recordQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            audioOutput.setSampleBufferDelegate(self, queue: recordQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
            isOutputConfigured = true
        }

        let previousInput = currentInput
        if let previousInput {
            session.removeInput(previousInput)
        }
        guard session.canAddInput(newInput) else {
            if let previousInput, session.canAddInput(previousInput) {
                session.addInput(previousInput)
            }
            throw CameraError.configurationFailed
        }
        session.addInput(newInput)
        currentInput = newInput

        photoOutput.maxPhotoQualityPrioritization = .balanced
        configurePhotoConnection(position: device.position)
        configureVideoConnection(position: device.position)
        applyDeviceDefaults(device)

        return CameraCapabilities(
            position: device.position,
            hasFlash: device.hasFlash,
            minZoom: device.minAvailableVideoZoomFactor,
            maxZoom: min(device.maxAvailableVideoZoomFactor, Self.maximumZoom)
        )
    }

    private func configurePhotoConnection(position: AVCaptureDevice.Position) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
    }

    private func configureVideoConnection(position: AVCaptureDevice.Position) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
    }

    // MARK: Video recording

    /// Starts writing a clip to `url`. Flipping the camera while recording keeps the same clip.
    func startRecording(to url: URL, withAudio: Bool) async -> Bool {
        let hasAudio: Bool = await withCheckedContinuation { continuation in
            queue.async {
                guard self.session.isRunning else {
                    continuation.resume(returning: false)
                    return
                }
                if withAudio, self.microphoneInput == nil,
                   let mic = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: mic) {
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.microphoneInput = input
                    }
                    self.session.commitConfiguration()
                }
                self.configureVideoConnection(position: self.currentInput?.device.position ?? .back)
                continuation.resume(returning: withAudio && self.microphoneInput != nil)
            }
        }
        return await withCheckedContinuation { continuation in
            recordQueue.async {
                do {
                    self.recorder = try VideoRecorder(url: url, hasAudio: hasAudio)
                    continuation.resume(returning: true)
                } catch {
                    self.recorder = nil
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Finishes the clip. Returns the file, or `nil` if nothing was recorded.
    func stopRecording() async -> URL? {
        await withCheckedContinuation { continuation in
            recordQueue.async {
                guard let recorder = self.recorder else {
                    continuation.resume(returning: nil)
                    return
                }
                self.recorder = nil
                recorder.finish { url in
                    continuation.resume(returning: url)
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let recorder else { return }
        if output === videoOutput {
            recorder.appendVideo(sampleBuffer)
        } else {
            recorder.appendAudio(sampleBuffer)
        }
    }

    private func applyDeviceDefaults(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        device.videoZoomFactor = max(1, device.minAvailableVideoZoomFactor)
        device.unlockForConfiguration()
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }
}

/// Writes one clip (H.264 720 x 960 + AAC). Used only on the engine's record queue.
private final class VideoRecorder: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var isSessionStarted = false

    init(url: URL, hasAudio: Bool) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 720,
            AVVideoHeightKey: 960,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw CameraError.captureFailed }
        writer.add(videoInput)
        if hasAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        if !isSessionStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            isSessionStarted = true
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(buffer)
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        guard isSessionStarted, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(buffer)
    }

    func finish(_ completion: @escaping @Sendable (URL?) -> Void) {
        guard isSessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            completion(nil)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let writer = self.writer
        let url = self.url
        writer.finishWriting {
            completion(writer.status == .completed ? url : nil)
        }
    }
}

/// Bridges `AVCapturePhotoCaptureDelegate` callbacks to a checked continuation.
private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, any Error>
    private let onFinish: @Sendable () -> Void
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<Data, any Error>, onFinish: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    private func resumeOnce(_ result: Result<Data, any Error>) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()
        if shouldResume {
            continuation.resume(with: result)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            resumeOnce(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            resumeOnce(.success(data))
        } else {
            resumeOnce(.failure(CameraError.captureFailed))
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        resumeOnce(.failure(error ?? CameraError.captureFailed))
        onFinish()
    }
}

// MARK: - Main-actor camera model

/// Observable camera state for the UI. Live capture only — there is no photo library access.
@MainActor
@Observable
final class CameraService {
    enum Status: Equatable {
        case idle
        case unauthorized
        case configuring
        case running
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var capabilities: CameraCapabilities?
    private(set) var zoomFactor: CGFloat = 1
    private(set) var isCapturing = false
    var flashMode: AVCaptureDevice.FlashMode = .off

    let engine = CaptureEngine()
    @ObservationIgnored private var isConfigured = false

    var session: AVCaptureSession { engine.session }
    var isFlashAvailable: Bool { capabilities?.hasFlash ?? false }

    /// Zoom presets supported by the current camera.
    var zoomPresets: [CGFloat] {
        let maxZoom = capabilities?.maxZoom ?? 1
        return [1, 2, 3].filter { $0 <= maxZoom }
    }

    nonisolated static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    nonisolated static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await Self.requestAccess() else {
                status = .unauthorized
                return
            }
        default:
            status = .unauthorized
            return
        }

        if !isConfigured {
            status = .configuring
            do {
                capabilities = try await engine.configure(position: position)
                isConfigured = true
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
        }
        await engine.start()
        status = .running
    }

    func stop() {
        engine.stop()
        if status == .running {
            status = .idle
        }
    }

    func flipCamera() async {
        guard isConfigured else { return }
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        do {
            let newCapabilities = try await engine.configure(position: next)
            capabilities = newCapabilities
            position = next
            zoomFactor = 1
            if !newCapabilities.hasFlash {
                flashMode = .off
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func cycleFlash() {
        guard isFlashAvailable else {
            flashMode = .off
            return
        }
        flashMode = switch flashMode {
        case .off: .auto
        case .auto: .on
        default: .off
        }
    }

    func setZoom(_ factor: CGFloat, animated: Bool) {
        let minZoom = capabilities?.minZoom ?? 1
        let maxZoom = capabilities?.maxZoom ?? 1
        let clamped = min(max(factor, max(1, minZoom)), max(1, maxZoom))
        zoomFactor = clamped
        engine.setZoom(clamped, animated: animated)
    }

    private(set) var isRecording = false

    /// Asks once for the microphone, so videos have sound.
    func prepareMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func startRecording() async -> Bool {
        guard status == .running, !isRecording, !isCapturing else { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        let withAudio = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        isRecording = await engine.startRecording(to: url, withAudio: withAudio)
        return isRecording
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        return await engine.stopRecording()
    }

    func capturePhoto() async throws -> Data {
        guard status == .running else { throw CameraError.sessionNotRunning }
        guard !isCapturing else { throw CameraError.captureFailed }
        isCapturing = true
        defer { isCapturing = false }
        return try await engine.capturePhoto(flashMode: isFlashAvailable ? flashMode : .off)
    }
}
