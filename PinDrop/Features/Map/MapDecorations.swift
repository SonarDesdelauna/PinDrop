import MapKit
import SwiftUI

// MARK: - Tire marks

/// One short piece of a tire mark (left or right wheel) behind the moving user.
struct SkidSegment: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let opacity: Double
}

enum SkidMarks {
    /// Distance between the two wheel tracks, in meters.
    static let trackHalfWidth: Double = 2.6
    static let lifetime: TimeInterval = 90
    static let maximumLength: Double = 350

    /// Builds two parallel tracks from the recent trail, fading with age and distance.
    static func segments(trail: [TrailPoint], current: GeoPoint?, now: Date = .now) -> [SkidSegment] {
        var points = trail
        if let current {
            points.append(TrailPoint(point: current, date: now))
        }
        guard points.count >= 2 else { return [] }
        var result: [SkidSegment] = []
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let metersPerDegreeLatitude = 111_320.0
            let metersPerDegreeLongitude = max(1, metersPerDegreeLatitude * cos(start.point.latitude * .pi / 180))
            let east = (end.point.longitude - start.point.longitude) * metersPerDegreeLongitude
            let north = (end.point.latitude - start.point.latitude) * metersPerDegreeLatitude
            let length = (east * east + north * north).squareRoot()
            guard length > 0.5, length < 120 else { continue }
            let perpendicularEast = -north / length
            let perpendicularNorth = east / length

            let age = now.timeIntervalSince(start.date)
            let distance = current.map { GeoClustering.haversineDistance(from: $0, to: start.point) } ?? 0
            let fade = max(0, 1 - age / lifetime) * max(0, 1 - distance / maximumLength)
            guard fade > 0.02 else { continue }

            for (side, sign) in [(0, 1.0), (1, -1.0)] {
                let offsetNorth = perpendicularNorth * trackHalfWidth * sign
                let offsetEast = perpendicularEast * trackHalfWidth * sign
                let a = start.point.offsetBy(northMeters: offsetNorth, eastMeters: offsetEast)
                let b = end.point.offsetBy(northMeters: offsetNorth, eastMeters: offsetEast)
                result.append(SkidSegment(id: index * 2 + side, coordinates: [a.coordinate, b.coordinate], opacity: 0.85 * fade))
            }
        }
        return result
    }
}

// MARK: - Objects orbiting the globe

/// Playful objects circling the planet when the map is zoomed out to the 3D globe.
/// Purely decorative: drawn over the map, ignored by hit testing and accessibility.
struct OrbitingObjectsView: View {
    private struct Orbit: Identifiable {
        let id: Int
        let symbol: String
        let radiusFactor: CGFloat
        let tilt: Double
        let flattening: CGFloat
        let period: Double
        let phase: Double
        let size: CGFloat
    }

    private struct Placement {
        let point: CGPoint
        let angle: Double
        let scale: Double
        let opacity: Double
        let isBehind: Bool
    }

    @State private var orbits: [Orbit] = []

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(orbits) { orbit in
                        let placement = Self.placement(of: orbit, time: time, in: size)
                        Text(verbatim: orbit.symbol)
                            .font(.system(size: orbit.size))
                            .rotationEffect(.radians(placement.angle))
                            .scaleEffect(placement.scale)
                            .opacity(placement.opacity)
                            .shadow(color: Color.white.opacity(placement.isBehind ? 0 : 0.35), radius: 6)
                            .position(placement.point)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if orbits.isEmpty {
                orbits = Self.randomOrbits()
            }
        }
    }

    private static func placement(of orbit: Orbit, time: Double, in size: CGSize) -> Placement {
        let width = Double(size.width)
        let height = Double(size.height)
        let globeRadius: Double = min(width, height) * 0.36
        let angle: Double = orbit.phase + time * 2 * Double.pi / orbit.period
        let radius: Double = globeRadius * Double(orbit.radiusFactor)
        let localX: Double = cos(angle) * radius
        let localY: Double = sin(angle) * radius * Double(orbit.flattening)
        let x: Double = localX * cos(orbit.tilt) - localY * sin(orbit.tilt)
        let y: Double = localX * sin(orbit.tilt) + localY * cos(orbit.tilt)
        // sin(angle) > 0 → the object is on the far side of the planet.
        let isBehind = sin(angle) > 0
        let distanceFromCenter: Double = (x * x + y * y).squareRoot()
        let hidden = isBehind && distanceFromCenter < globeRadius * 0.98
        let scale: Double = isBehind ? 0.7 : 1.0 + 0.15 * abs(sin(angle))
        let opacity: Double = hidden ? 0 : (isBehind ? 0.55 : 1)
        return Placement(
            point: CGPoint(x: width / 2 + x, y: height / 2 + y),
            angle: angle + Double.pi / 2 + orbit.tilt,
            scale: scale,
            opacity: opacity,
            isBehind: isBehind
        )
    }

    private static func randomOrbits() -> [Orbit] {
        let symbols = ["🛰️", "🚀", "🛸", "✈️", "🌙", "☄️", "🎈", "⭐️", "🪐", "🛰️"]
        let count = Int.random(in: 5...7)
        return (0..<count).map { index in
            Orbit(
                id: index,
                symbol: symbols.randomElement() ?? "🛰️",
                radiusFactor: CGFloat.random(in: 1.12...1.55),
                tilt: Double.random(in: -0.9...0.9),
                flattening: CGFloat.random(in: 0.22...0.5),
                period: Double.random(in: 9...22) * (Bool.random() ? 1 : -1),
                phase: Double.random(in: 0...(2 * .pi)),
                size: CGFloat.random(in: 20...30)
            )
        }
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
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
