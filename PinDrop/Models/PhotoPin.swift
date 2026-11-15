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

    /// Anchor used when no location is available yet (Piazza del Duomo, Milan).
    static let fallback = GeoPoint(latitude: 45.4642, longitude: 9.1900)
}

/// An emoji reaction left on a pin (`public.reactions`).
struct Reaction: Identifiable, Decodable, Hashable, Sendable {
    let userID: UUID
    let emoji: String
    let createdAt: Date

    var id: String {
        "\(userID.uuidString)-\(emoji)"
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case emoji
        case createdAt = "created_at"
    }
}

/// A live photo drop (`public.pins`). Lives exactly 6 hours, enforced by the server.
struct PhotoPin: Identifiable, Decodable, Sendable {
    /// Lifetime of every pin: 6 hours.
    static let lifetime: TimeInterval = 21_600
    /// Reactions offered in the viewer (must match the database check constraint).
    static let reactionPalette: [String] = ["🔥", "😍", "😂", "👀", "🫶"]

    /// Columns requested from PostgREST, with the author profile and reactions embedded.
    static let selectColumns = "id, latitude, longitude, place_name, caption, image_path, thumb_path, blur_path, created_at, expires_at, author:profiles!pins_author_id_fkey(*), reactions(user_id, emoji, created_at)"

    let id: UUID
    var author: UserProfile
    let latitude: Double
    let longitude: Double
    var placeName: String?
    var caption: String
    /// Storage paths inside the private `pins` bucket.
    let imagePath: String
    let thumbPath: String
    let blurPath: String
    let createdAt: Date
    let expiresAt: Date
    var reactions: [Reaction]

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case latitude
        case longitude
        case placeName = "place_name"
        case caption
        case imagePath = "image_path"
        case thumbPath = "thumb_path"
        case blurPath = "blur_path"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case reactions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        author = try container.decode(UserProfile.self, forKey: .author)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        placeName = try container.decodeIfPresent(String.self, forKey: .placeName)
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        imagePath = try container.decode(String.self, forKey: .imagePath)
        thumbPath = try container.decode(String.self, forKey: .thumbPath)
        blurPath = try container.decode(String.self, forKey: .blurPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        reactions = try container.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
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
