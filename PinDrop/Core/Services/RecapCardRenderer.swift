import MapKit
import SwiftUI
import UIKit

/// Renders the evening recap as a 9:16 story card (1080×1920 px): dark glass look, mini-map
/// with the neon trail, photo collage, statistics and a "PinDrop" watermark.
@MainActor
enum RecapCardRenderer {
    /// Layout size in points; rendered at 3× = 1080×1920 px.
    static let canvasSize = CGSize(width: 360, height: 640)
    static let mapSize = CGSize(width: 328, height: 236)

    static func render(summary: TrailSummary, userName: String, photos: [UIImage]) async -> UIImage? {
        let start = UIColor(Theme.electricViolet)
        let end = UIColor(Theme.neonPurple)
        let mapImage = await mapSnapshot(points: summary.points, size: mapSize, start: start, end: end)
        let card = RecapCardView(summary: summary, userName: userName, mapImage: mapImage, photos: Array(photos.prefix(4)))
            .frame(width: canvasSize.width, height: canvasSize.height)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(canvasSize)
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Saves the card as a PNG in the temporary folder, ready for the share sheet.
    static func writePNG(_ image: UIImage) -> URL? {
        guard let data = image.pngData() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinDrop-Recap-\(formatter.string(from: .now)).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A dark map snapshot with the trail drawn as a glowing dashed line and a dot per pin.
    nonisolated static func mapSnapshot(points: [GeoPoint], size: CGSize, start: UIColor, end: UIColor) async -> UIImage? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for point in points {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let latitudeMeters = max(600, (maxLat - minLat) * 111_320 * 1.6)
        let longitudeMeters = max(600, (maxLon - minLon) * 111_320 * cos(center.latitude * Double.pi / 180) * 1.6)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: latitudeMeters, longitudinalMeters: longitudeMeters)
        options.size = size
        options.scale = 3
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            snapshot.image.draw(at: .zero)
            let cg = context.cgContext
            let screenPoints = points.map { snapshot.point(for: $0.coordinate) }
            if screenPoints.count >= 2 {
                let path = CGMutablePath()
                path.addLines(between: screenPoints)

                cg.saveGState()
                cg.addPath(path)
                cg.setLineWidth(10)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.setStrokeColor(start.withAlphaComponent(0.35).cgColor)
                cg.strokePath()
                cg.restoreGState()

                cg.saveGState()
                cg.addPath(path)
                cg.setLineWidth(4)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.setLineDash(phase: 0, lengths: [8, 6])
                cg.replacePathWithStrokedPath()
                cg.clip()
                let colors = [start.cgColor, end.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]),
                   let firstPoint = screenPoints.first, let lastPoint = screenPoints.last {
                    cg.drawLinearGradient(gradient, start: firstPoint, end: lastPoint, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
                cg.restoreGState()
            }
            for (index, point) in screenPoints.enumerated() {
                let radius: CGFloat = index == screenPoints.count - 1 ? 7 : 5
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: rect.insetBy(dx: -2, dy: -2))
                cg.setFillColor((index == screenPoints.count - 1 ? end : start).cgColor)
                cg.fillEllipse(in: rect)
            }
        }
    }
}

/// The story card itself. Uses plain translucent fills (no live materials) so it renders
/// identically off screen.
struct RecapCardView: View {
    let summary: TrailSummary
    let userName: String
    let mapImage: UIImage?
    let photos: [UIImage]

    var body: some View {
        ZStack {
            Theme.obsidian
            RadialGradient(colors: [Theme.electricViolet.opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Theme.emerald.opacity(0.25), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 320)

            VStack(alignment: .leading, spacing: 14) {
                header
                map
                stats
                if !photos.isEmpty {
                    collage
                }
                Spacer(minLength: 0)
                watermark
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("recap.card.kicker")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.neonPurple)
                .textCase(.uppercase)
                .tracking(1.5)
            Text("recap.card.title \(userName)")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                Text(summary.startedAt, style: .time)
                Image(systemName: "arrow.right")
                Text(summary.endedAt, style: .time)
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var map: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "map.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.neonPurple.opacity(0.6))
            }
        }
        .frame(height: RecapCardRenderer.mapSize.height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.electricViolet, Theme.neonPurple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
        }
    }

    private var stats: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tile(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", value: Text(verbatim: summary.distanceText), label: Text("recap.stat.distance"))
                tile(icon: "mappin.and.ellipse", value: Text(summary.spotCount, format: .number), label: Text("recap.stat.spots"))
            }
            HStack(spacing: 8) {
                tile(icon: "person.2.fill", value: Text(summary.friendsMet.count, format: .number), label: Text("recap.stat.friends"))
                tile(icon: "camera.fill", value: Text(summary.pins.count, format: .number), label: Text("recap.stat.photos"))
            }
            if !summary.friendsMet.isEmpty {
                Text("recap.card.with \(summary.friendsMet.prefix(4).map(\.firstName).joined(separator: ", "))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.emeraldLight)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tile(icon: String, value: Text, label: Text) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(LinearGradient(colors: [Theme.electricViolet, Theme.neonPurple], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 0) {
                value
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                label
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var collage: some View {
        HStack(spacing: 6) {
            ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                Color.clear
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .rotationEffect(.degrees(index.isMultiple(of: 2) ? -2 : 2))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var watermark: some View {
        HStack(spacing: 8) {
            AppLogoView(size: 24)
            Text(verbatim: "PinDrop")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Color.white, Theme.neonPurple], startPoint: .leading, endPoint: .trailing))
            Spacer(minLength: 0)
            Text("recap.card.footer")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
