import CoreLocation
import Foundation

/// A Sendable latitude/longitude pair, safe to pass across actors and to encode.
struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A point moved by the given offsets (meters), using a local equirectangular approximation.
    func offsetBy(northMeters: Double, eastMeters: Double) -> GeoPoint {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(1, metersPerDegreeLatitude * cos(latitude * .pi / 180))
        return GeoPoint(
            latitude: latitude + northMeters / metersPerDegreeLatitude,
            longitude: longitude + eastMeters / metersPerDegreeLongitude
        )
    }

    /// Demo anchor used when no location is available yet (Piazza del Duomo, Milan).
    static let fallback = GeoPoint(latitude: 45.4642, longitude: 9.1900)
}

/// An emoji reaction left on a pin.
struct Reaction: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let emoji: String
    let userID: UUID
    let createdAt: Date
}

/// A live photo drop. Lives exactly 6 hours (21,600 s) from its creation.
struct PhotoPin: Identifiable, Codable, Sendable {
    /// Lifetime of every pin: 6 hours.
    static let lifetime: TimeInterval = 21_600
    /// Reactions offered in the viewer.
    static let reactionPalette: [String] = ["🔥", "😍", "😂", "👀", "🫶"]

    let id: UUID
    var author: UserProfile
    let imageData: Data
    let thumbnailData: Data
    let latitude: Double
    let longitude: Double
    var placeName: String?
    var caption: String
    let createdAt: Date
    let expiresAt: Date
    var reactions: [Reaction]

    init(
        id: UUID = UUID(),
        author: UserProfile,
        imageData: Data,
        thumbnailData: Data,
        location: GeoPoint,
        placeName: String?,
        caption: String,
        createdAt: Date = .now,
        reactions: [Reaction] = []
    ) {
        self.id = id
        self.author = author
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.latitude = location.latitude
        self.longitude = location.longitude
        self.placeName = placeName
        self.caption = caption
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(Self.lifetime)
        self.reactions = reactions
    }

    var location: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        location.coordinate
    }

    func remainingTime(at date: Date = .now) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(date))
    }

    /// 1 when just created, 0 when expired. Drives the circular countdown ring.
    func remainingFraction(at date: Date = .now) -> Double {
        let total = expiresAt.timeIntervalSince(createdAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, remainingTime(at: date) / total))
    }

    func isExpired(at date: Date = .now) -> Bool {
        date >= expiresAt
    }

    func reactionCount(for emoji: String) -> Int {
        reactions.reduce(0) { $0 + ($1.emoji == emoji ? 1 : 0) }
    }

    func hasReaction(_ emoji: String, from userID: UUID) -> Bool {
        reactions.contains { $0.emoji == emoji && $0.userID == userID }
    }
}

extension PhotoPin: Hashable {
    /// Equality ignores the (immutable) image payload to keep SwiftUI diffing cheap.
    static func == (lhs: PhotoPin, rhs: PhotoPin) -> Bool {
        lhs.id == rhs.id
            && lhs.author == rhs.author
            && lhs.caption == rhs.caption
            && lhs.placeName == rhs.placeName
            && lhs.reactions == rhs.reactions
            && lhs.expiresAt == rhs.expiresAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
