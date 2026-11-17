import MapKit
import SwiftUI

// MARK: - Motion trail

/// One short piece of the glowing tail behind the moving user.
struct SkidSegment: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    /// 1 right behind you → 0 at the end of the tail.
    let fade: Double
}

enum SkidMarks {
    /// The tail is short: a few seconds and a few dozen meters behind you.
    static let lifetime: TimeInterval = 9
    static let maximumLength: Double = 35

    /// Builds a short comet tail from the recent trail, fading with age and distance.
    static func segments(trail: [TrailPoint], current: GeoPoint?, now: Date = .now) -> [SkidSegment] {
        guard let current else { return [] }
        var points = trail.filter {
            now.timeIntervalSince($0.date) < lifetime
                && GeoClustering.haversineDistance(from: current, to: $0.point) < maximumLength
        }
        points.append(TrailPoint(point: current, date: now))
        guard points.count >= 2 else { return [] }
        var result: [SkidSegment] = []
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let length = GeoClustering.haversineDistance(from: start.point, to: end.point)
            guard length > 0.3, length < 40 else { continue }
            let age = now.timeIntervalSince(start.date)
            let distance = GeoClustering.haversineDistance(from: current, to: start.point)
            let fade = max(0, 1 - age / lifetime) * max(0, 1 - distance / maximumLength)
            guard fade > 0.03 else { continue }
            result.append(SkidSegment(id: index, coordinates: [start.point.coordinate, end.point.coordinate], fade: fade))
        }
        return result
    }
}

// MARK: - Far zoom location dot

/// Your position when the map is zoomed far out: just a dot, like Apple Maps.
struct MyLocationDotView: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.electricViolet.opacity(0.22))
                .frame(width: 40, height: 40)
                .scaleEffect(isPulsing ? 1.15 : 0.55)
                .opacity(isPulsing ? 0 : 1)
            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .shadow(color: Color.black.opacity(0.28), radius: 4, y: 1)
            Circle()
                .fill(Theme.accentGradient)
                .frame(width: 15, height: 15)
        }
        .frame(width: 44, height: 44)
        .onAppear {
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// The app logo (same artwork as the app icon).
struct AppLogoView: View {
    var size: CGFloat = 40

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .scaleEffect(1.08)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(Theme.ink.opacity(0.18), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
