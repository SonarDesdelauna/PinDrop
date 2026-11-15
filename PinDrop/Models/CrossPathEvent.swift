import Foundation

/// A cross-path stored by the server (`public.cross_paths`).
struct CrossPathRow: Decodable, Hashable, Sendable {
    let id: UUID
    let userA: UUID
    let userB: UUID
    let pinA: UUID
    let pinB: UUID
    let latitude: Double
    let longitude: Double
    let distanceMeters: Double
    let deltaSeconds: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userA = "user_a"
        case userB = "user_b"
        case pinA = "pin_a"
        case pinB = "pin_b"
        case latitude
        case longitude
        case distanceMeters = "distance_m"
        case deltaSeconds = "delta_seconds"
        case createdAt = "created_at"
    }
}

/// "Sfiorati": you and a friend dropped a pin in the same spot (under 40 m) at different
/// times (more than 5 minutes apart) without meeting. Both photos unlock for both of you.
struct CrossPathEvent: Identifiable, Hashable, Sendable {
    /// Two pins farther apart than this are not a cross-path (meters).
    static let maximumDistance: Double = 40
    /// Two pins closer in time than this mean you were there together (seconds).
    static let minimumTimeDelta: TimeInterval = 300
    /// Only pins of the last 6 hours are compared.
    static let lookback: TimeInterval = 21_600

    let id: UUID
    let friend: UserProfile
    let myPinID: UUID
    let friendPinID: UUID
    let location: GeoPoint
    let distanceMeters: Double
    let timeDelta: TimeInterval
    let detectedAt: Date

    /// "25 min" — how far apart in time you passed by.
    var timeDeltaText: String {
        LocaleFormatter.walkingDuration(seconds: timeDelta)
    }

    var distanceText: String {
        LocaleFormatter.distance(meters: distanceMeters)
    }
}
