import AVFoundation
import CoreImage
import SwiftUI
import UIKit

// MARK: - Playback

/// A video that loops forever, filling its frame (like a photo).
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var isPlaying = true
    var isMuted = false
    /// Optional effect applied while playing (story editor preview).
    var composition: AVVideoComposition?
    /// Change it to rebuild the player when `composition` changes.
    var compositionID = ""

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        context.coordinator.load(url: url, composition: composition, id: compositionID, in: view)
        context.coordinator.player.isMuted = isMuted
        if isPlaying { context.coordinator.player.play() }
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedURL != url || coordinator.loadedCompositionID != compositionID {
            coordinator.load(url: url, composition: composition, id: compositionID, in: view)
        }
        coordinator.player.isMuted = isMuted
        if isPlaying {
            if coordinator.player.timeControlStatus != .playing { coordinator.player.play() }
        } else {
            coordinator.player.pause()
        }
    }

    static func dismantleUIView(_ view: PlayerContainerView, coordinator: Coordinator) {
        coordinator.player.pause()
        coordinator.player.removeAllItems()
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var loadedURL: URL?
        var loadedCompositionID = ""

        func load(url: URL, composition: AVVideoComposition?, id: String, in view: PlayerContainerView) {
            let wasPlaying = player.timeControlStatus == .playing || loadedURL == nil
            player.removeAllItems()
            let item = AVPlayerItem(url: url)
            item.videoComposition = composition
            looper = AVPlayerLooper(player: player, templateItem: item)
            view.playerLayer.player = player
            loadedURL = url
            loadedCompositionID = id
            if wasPlaying { player.play() }
        }
    }
}

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}

/// A video stored on the server ("bucket/path"): downloaded once, then played in a loop.
/// The poster photo stays underneath while it loads.
struct RemoteVideoView: View {
    @Environment(AppState.self) private var appState

    let key: String
    var isPlaying = true
    var isMuted = false
    var onReady: ((Double) -> Void)?

    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                LoopingVideoView(url: url, isPlaying: isPlaying, isMuted: isMuted)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .tint(Color.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) {
            url = nil
            guard let file = try? await appState.dataService.videoFile(key: key) else { return }
            let duration = await VideoTools.duration(of: file)
            withAnimation(.easeOut(duration: 0.2)) { url = file }
            onReady?(duration)
        }
    }
}

/// "▶" badge for drops that are videos.
struct VideoBadge: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Color.white)
            .frame(width: 18, height: 18)
            .background(Color.black.opacity(0.55), in: Circle())
            .overlay { Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

// MARK: - Tools

@MainActor
enum VideoTools {
    static let maxDuration: Double = 10
    static let storySize = CGSize(width: 720, height: 1280)

    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return maxDuration }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : maxDuration
    }

    /// The first frame as a JPEG (used as the photo of a video drop).
    static func posterJPEG(for url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.05, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.92)
    }

    /// Live preview of a story effect on a video.
    static func previewComposition(for url: URL, effect: StoryEffect) async -> AVVideoComposition? {
        guard effect != .original else { return nil }
        let asset = AVURLAsset(url: url)
        return try? await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: previewHandler(effect: effect))
    }

    /// Built outside the main actor: the frames are filtered on AVFoundation's threads.
    nonisolated private static func previewHandler(effect: StoryEffect) -> @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void {
        { request in
            let source = request.sourceImage
            request.finish(with: effect.applyCI(source).cropped(to: source.extent), context: nil)
        }
    }

    nonisolated private static func storyHandler(effect: StoryEffect, overlay: UIImage?, size: CGSize) -> @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void {
        let overlayImage: CIImage? = overlay?.cgImage.map { CIImage(cgImage: $0) }.map { image in
            image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
        }
        nonisolated(unsafe) let layers = overlayImage
        return { request in
            let source = request.sourceImage
            let extent = source.extent
            let scale = max(size.width / extent.width, size.height / extent.height)
            let width = extent.width * scale
            let height = extent.height * scale
            let frame = CGRect(origin: .zero, size: size)
            var image = source
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: -(width - size.width) / 2, y: -(height - size.height) / 2))
                .cropped(to: frame)
            image = effect.applyCI(image).cropped(to: frame)
            if let layers {
                image = layers.composited(over: image)
            }
            request.finish(with: image.cropped(to: frame), context: nil)
        }
    }

    /// Renders a 9:16 story video: crop to fill, effect, then texts and stickers on top.
    static func exportStory(video url: URL, effect: StoryEffect, overlay: UIImage?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let size = storySize
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: storyHandler(effect: effect, overlay: overlay, size: size))
        composition.renderSize = size
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CameraError.captureFailed
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("story-\(UUID().uuidString).mp4")
        try await session.export(to: output, as: .mp4)
        return output
    }
}
