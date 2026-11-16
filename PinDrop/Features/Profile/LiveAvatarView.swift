import Photos
import PhotosUI
import SwiftUI

/// The original still + paired video of a Live Photo, ready to upload as a profile picture.
struct LiveAvatarDraft: Sendable {
    let photo: Data
    /// "heic" or "jpg", as the original still.
    let photoExtension: String
    let video: Data
}

/// Reads the original resources of a picked Live Photo and rebuilds playable ones from files.
enum LivePhotoLoader {
    /// The original still + video of a Live Photo chosen in the picker.
    @MainActor
    static func draft(from item: PhotosPickerItem) async -> LiveAvatarDraft? {
        if let livePhoto = try? await item.loadTransferable(type: PHLivePhoto.self) {
            let resources = PHAssetResource.assetResources(for: livePhoto)
            if let draft = await draft(from: resources) {
                return draft
            }
        }
        // Fallback: read the asset from the library (asks for access the first time).
        guard let identifier = item.itemIdentifier else { return nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaSubtypes.contains(.photoLive) else { return nil }
        return await draft(from: PHAssetResource.assetResources(for: asset))
    }

    @MainActor
    private static func draft(from resources: [PHAssetResource]) async -> LiveAvatarDraft? {
        guard let photoResource = resources.first(where: { $0.type == .photo }) ?? resources.first(where: { $0.type == .fullSizePhoto }),
              let videoResource = resources.first(where: { $0.type == .pairedVideo }) ?? resources.first(where: { $0.type == .fullSizePairedVideo })
        else { return nil }
        guard let photo = await data(for: photoResource), let video = await data(for: videoResource) else { return nil }
        // Keep uploads small: very long or heavy Live Photos fall back to a still picture.
        guard photo.count + video.count < 14_000_000 else { return nil }
        let name = photoResource.originalFilename.lowercased()
        let ext = (name.hasSuffix(".heic") || name.hasSuffix(".heif")) ? "heic" : "jpg"
        return LiveAvatarDraft(photo: photo, photoExtension: ext, video: video)
    }

    @MainActor
    private static func data(for resource: PHAssetResource) async -> Data? {
        let buffer = DataBuffer()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { @Sendable chunk in
                buffer.append(chunk)
            }, completionHandler: { @Sendable error in
                continuation.resume(returning: error == nil ? buffer.data : nil)
            })
        }
    }

    /// A playable Live Photo from a still and its paired video on disk.
    @MainActor
    static func livePhoto(photoURL: URL, videoURL: URL) async -> PHLivePhoto? {
        let box = LivePhotoBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PHLivePhoto.request(
                withResourceFileURLs: [photoURL, videoURL],
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFill
            ) { @Sendable photo, info in
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                let failed = info[PHLivePhotoInfoErrorKey] != nil || ((info[PHLivePhotoInfoCancelledKey] as? Bool) ?? false)
                if degraded && !failed { return }
                box.finish(failed ? nil : photo, continuation)
            }
        }
        return box.photo
    }

    /// Local copies of a profile's Live Photo (downloaded once, then cached).
    static func cachedFiles(photoPath: String, videoPath: String) async -> (URL, URL)? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("live-avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func local(_ path: String) -> URL {
            folder.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        }
        let photoURL = local(photoPath)
        let videoURL = local(videoPath)
        for (path, url) in [(photoPath, photoURL), (videoPath, videoURL)] where !FileManager.default.fileExists(atPath: url.path) {
            guard let remote = SupabaseConfig.publicAvatarURL(path: path),
                  let (data, response) = try? await URLSession.shared.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try? data.write(to: url, options: .atomic)
        }
        return (photoURL, videoURL)
    }

    /// Writes a picked Live Photo to temporary files (for the edit preview).
    static func temporaryFiles(for draft: LiveAvatarDraft) -> (URL, URL)? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let photoURL = folder.appendingPathComponent("live.\(draft.photoExtension)")
            let videoURL = folder.appendingPathComponent("live.mov")
            try draft.photo.write(to: photoURL)
            try draft.video.write(to: videoURL)
            return (photoURL, videoURL)
        } catch {
            return nil
        }
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LivePhotoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isDone = false
    private(set) var photo: PHLivePhoto?

    func finish(_ value: PHLivePhoto?, _ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard !isDone else {
            lock.unlock()
            return
        }
        isDone = true
        photo = value
        lock.unlock()
        continuation.resume()
    }
}

/// A profile picture that plays its Live Photo (once when it appears, again on tap or long press).
/// Falls back to the regular avatar when there is no Live Photo.
struct LiveAvatarView: View {
    let user: UserProfile
    let size: CGFloat
    /// A Live Photo just picked and not uploaded yet.
    var draft: LiveAvatarDraft?
    /// Still image to show for a picked photo that is not live.
    var stillImage: UIImage?

    @State private var livePhoto: PHLivePhoto?

    private var loadKey: String {
        if let draft { return "draft-\(draft.photo.count)-\(draft.video.count)" }
        return [user.avatarLivePhotoPath, user.avatarLiveVideoPath].compactMap { $0 }.joined(separator: "|")
    }

    var body: some View {
        ZStack {
            if let stillImage {
                Image(uiImage: stillImage)
                    .resizable()
                    .scaledToFill()
            } else {
                AvatarBadge(user: user, size: size)
            }
            if let livePhoto {
                LivePhotoPlayer(livePhoto: livePhoto)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomLeading) {
            if livePhoto != nil {
                Image(systemName: "livephoto")
                    .font(.system(size: max(11, size * 0.13), weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(5)
                    .background(Circle().fill(.ultraThinMaterial))
                    .offset(x: -2, y: 2)
                    .allowsHitTesting(false)
            }
        }
        .task(id: loadKey) {
            livePhoto = nil
            let files: (URL, URL)?
            if let draft {
                files = LivePhotoLoader.temporaryFiles(for: draft)
            } else if let photoPath = user.avatarLivePhotoPath, let videoPath = user.avatarLiveVideoPath {
                files = await LivePhotoLoader.cachedFiles(photoPath: photoPath, videoPath: videoPath)
            } else {
                files = nil
            }
            guard let files, !Task.isCancelled else { return }
            let photo = await LivePhotoLoader.livePhoto(photoURL: files.0, videoURL: files.1)
            withAnimation(.easeOut(duration: 0.25)) {
                livePhoto = photo
            }
        }
    }
}

private struct LivePhotoPlayer: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isMuted = true
        view.livePhoto = livePhoto
        context.coordinator.view = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.play))
        view.addGestureRecognizer(tap)
        let coordinator = context.coordinator
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            coordinator.play()
        }
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: PHLivePhotoView?

        @objc func play() {
            view?.startPlayback(with: .full)
        }
    }
}
