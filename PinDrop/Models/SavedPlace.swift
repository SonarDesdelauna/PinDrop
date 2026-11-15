import CoreLocation
import Foundation

/// A place the user saved, with visit statistics (`public.my_places()`). Private to its owner.
struct SavedPlace: Identifiable, Decodable, Hashable, Sendable {
    static let defaultRadius = 100
    static let emojiPalette: [String] = ["📍", "🏠", "🏫", "💼", "☕️", "🍕", "🏋️", "🌳", "🎵", "🛍️", "🍻", "❤️"]

    let id: UUID
    var name: String
    var emoji: String
    let latitude: Double
    let longitude: Double
    let radiusM: Int
    let isPublic: Bool
    let createdAt: Date
    let visitCount: Int
    let lastVisitAt: Date?
    /// Start of the ongoing visit, when the user is (or was in the last 2 hours) there.
    let currentArrivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case emoji
        case latitude
        case longitude
        case radiusM = "radius_m"
        case isPublic = "is_public"
        case createdAt = "created_at"
        case visitCount = "visit_count"
        case lastVisitAt = "last_visit_at"
        case currentArrivedAt = "current_arrived_at"
    }

    var location: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        location.coordinate
    }

    func contains(_ point: GeoPoint) -> Bool {
        GeoClustering.haversineDistance(from: location, to: point) <= Double(radiusM)
    }
}

/// Where the user is right now and since when. Kept on the device only.
struct PresenceState: Codable, Equatable, Sendable {
    var anchor: GeoPoint
    var since: Date
    var lastSeen: Date

    /// Moving farther than this from the anchor counts as leaving.
    static let leaveDistance: Double = 80
    /// If the app was not used for longer than this, the stay is considered over.
    static let maximumGap: TimeInterval = 6 * 3_600
}
