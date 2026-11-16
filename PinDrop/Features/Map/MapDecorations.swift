import MapKit
import QuartzCore
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

// MARK: - Objects orbiting the globe

/// Drives the orbits from the display refresh, also while the map is being dragged,
/// so the objects keep their own pace whatever you do with the globe.
@MainActor
private final class OrbitTicker: NSObject {
    private var link: CADisplayLink?
    private var onTick: ((Double) -> Void)?

    func start(_ handler: @escaping (Double) -> Void) {
        onTick = handler
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onTick = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        onTick?(link.timestamp)
    }
}

/// Playful objects circling the planet when the map is zoomed out to the 3D globe.
/// They move on their own clock, fixed to the screen: turning or dragging the globe
/// never moves them. Purely decorative, ignored by hit testing and accessibility.
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
    @State private var time: Double = 0
    @State private var ticker = OrbitTicker()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
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
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if orbits.isEmpty {
                orbits = Self.randomOrbits()
            }
            time = CACurrentMediaTime()
            ticker.start { now in
                time = now
            }
        }
        .onDisappear {
            ticker.stop()
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
