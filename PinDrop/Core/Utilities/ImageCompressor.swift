import UIKit
import ImageIO

/// Output of the capture pipeline: a 3:4 portrait JPEG, a square thumbnail and a
/// pre-blurred preview (the only variant friends can download while their map is locked).
struct ProcessedImage: Sendable, Equatable {
    let fullData: Data
    let thumbnailData: Data
    let blurData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Resizing, 3:4 cropping, JPEG compression and thumbnail generation.
/// Every function is thread-safe and can run off the main actor.
enum ImageCompressor {
    static let fullLongEdge: CGFloat = 1600
    static let thumbnailEdge: CGFloat = 360
    static let fullQuality: CGFloat = 0.82
    static let thumbnailQuality: CGFloat = 0.72
    static let portraitAspect: CGFloat = 3.0 / 4.0
    static let blurSourceEdge: CGFloat = 12
    static let blurOutputEdge: CGFloat = 96

    /// Decodes raw camera data (HEIC/JPEG), normalizes orientation, crops to 3:4 and compresses.
    static func process(_ data: Data) -> ProcessedImage? {
        guard let decoded = downsample(data, maxPixelSize: fullLongEdge * 1.5) else { return nil }
        // Live captures are always portrait: a landscape buffer means the sensor orientation
        // was not applied, so rotate it upright before cropping.
        let upright = decoded.size.width > decoded.size.height ? rotateClockwise(decoded) : decoded
        let full = cropAndResize(upright, aspect: portraitAspect, longEdge: fullLongEdge)
        guard let fullData = full.jpegData(compressionQuality: fullQuality) else { return nil }
        let thumbnail = cropAndResize(full, aspect: 1, longEdge: thumbnailEdge)
        guard let thumbnailData = thumbnail.jpegData(compressionQuality: thumbnailQuality) else { return nil }
        guard let blurData = blurredPreview(of: thumbnail).jpegData(compressionQuality: 0.6) else { return nil }
        return ProcessedImage(
            fullData: fullData,
            thumbnailData: thumbnailData,
            blurData: blurData,
            pixelWidth: Int(full.size.width),
            pixelHeight: Int(full.size.height)
        )
    }

    /// Memory-efficient decode with ImageIO; EXIF orientation is applied to the pixels.
    static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Rotates an image 90° clockwise.
    static func rotateClockwise(_ image: UIImage) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.height, height: size.width), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.height, y: 0)
            cg.rotate(by: .pi / 2)
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Unrecognizable preview: downscaled to a few pixels, then smoothly upscaled.
    static func blurredPreview(of image: UIImage) -> UIImage {
        let tiny = resized(image, to: CGSize(width: blurSourceEdge, height: blurSourceEdge), quality: .medium)
        return resized(tiny, to: CGSize(width: blurOutputEdge, height: blurOutputEdge), quality: .high)
    }

    private static func resized(_ image: UIImage, to size: CGSize, quality: CGInterpolationQuality) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            context.cgContext.interpolationQuality = quality
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Center-crops `image` to `aspect` (width / height) and scales it so its long edge is at most `longEdge`.
    static func cropAndResize(_ image: UIImage, aspect: CGFloat, longEdge: CGFloat) -> UIImage {
        let source = image.size
        guard source.width > 0, source.height > 0, aspect > 0 else { return image }

        var cropSize = source
        if source.width / source.height > aspect {
            cropSize.width = source.height * aspect
        } else {
            cropSize.height = source.width / aspect
        }

        let scale = min(1, longEdge / max(cropSize.width, cropSize.height))
        let outputSize = CGSize(
            width: max(1, floor(cropSize.width * scale)),
            height: max(1, floor(cropSize.height * scale))
        )
        let drawSize = CGSize(width: source.width * scale, height: source.height * scale)
        let origin = CGPoint(
            x: (outputSize.width - drawSize.width) / 2,
            y: (outputSize.height - drawSize.height) / 2
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

/// Main-actor cache of decoded images, keyed by storage path.
@MainActor
enum ImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        return cache
    }()

    static func image(forKey key: String, data: Data) -> UIImage? {
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}
