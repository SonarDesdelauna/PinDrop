import CoreLocation
import Foundation

/// A secret photo + message anchored to a spot for 24 hours (`public.geo_capsules`).
/// Friends see where it is and a hint; it opens only when they stand within 20 m.
struct GeoCapsule: Identifiable, Decodable, Hashable, Sendable {
    static let lifetime: TimeInterval = 86_400
    /// The capsule opens below this distance (meters).
    static let unlockRadius: Double = 20
    /// The 20 m circle is drawn on the map below this distance (meters).
    static let circleVisibleDistance: Double = 600
    static let hintLimit = 80
    static let messageLimit = 140

    static let selectColumns = "id, latitude, longitude, hint, image_path, thumb_path, video_path, created_at, expires_at, recipient_id, author:profiles!geo_capsules_author_id_fkey(*)"

    let id: UUID
    var author: UserProfile
    let recipientID: UUID?
    let latitude: Double
    let longitude: Double
    let hint: String
    /// Storage paths inside the private `capsules` bucket.
    let imagePath: String
    let thumbPath: String
    /// The MP4 when the capsule hides a video.
    var videoPath: String? = nil
    let createdAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case recipientID = "recipient_id"
        case latitude
        case longitude
        case hint
        case imagePath = "image_path"
        case thumbPath = "thumb_path"
        case videoPath = "video_path"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    init(
        id: UUID,
        author: UserProfile,
        recipientID: UUID?,
        latitude: Double,
        longitude: Double,
        hint: String,
        imagePath: String,
        thumbPath: String,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.author = author
        self.recipientID = recipientID
        self.latitude = latitude
        self.longitude = longitude
        self.hint = hint
        self.imagePath = imagePath
        self.thumbPath = thumbPath
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        author = try container.decode(UserProfile.self, forKey: .author)
        recipientID = try container.decodeIfPresent(UUID.self, forKey: .recipientID)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        hint = try container.decodeIfPresent(String.self, forKey: .hint) ?? ""
        imagePath = try container.decode(String.self, forKey: .imagePath)
        thumbPath = try container.decode(String.self, forKey: .thumbPath)
        videoPath = try container.decodeIfPresent(String.self, forKey: .videoPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }

    var location: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        location.coordinate
    }

    func isExpired(at date: Date = .now) -> Bool {
        date >= expiresAt
    }

    func remainingTime(at date: Date = .now) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(date))
    }

    /// 1 when just hidden, 0 when expired.
    func remainingFraction(at date: Date = .now) -> Double {
        let total = expiresAt.timeIntervalSince(createdAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, remainingTime(at: date) / total))
    }
}

/// The secret message of a capsule (`public.capsule_secrets`), readable once opened.
struct CapsuleSecret: Decodable, Sendable {
    let capsuleID: UUID
    let message: String

    enum CodingKeys: String, CodingKey {
        case capsuleID = "capsule_id"
        case message
    }
}

/// Who opened which capsule (`public.capsule_opens`): yours, and the ones of your capsules.
struct CapsuleOpenRow: Decodable, Hashable, Sendable {
    let capsuleID: UUID
    let userID: UUID
    let openedAt: Date

    enum CodingKeys: String, CodingKey {
        case capsuleID = "capsule_id"
        case userID = "user_id"
        case openedAt = "opened_at"
    }
}

/// Everything needed to hide a new capsule.
struct CapsuleDraft: Sendable {
    let image: ProcessedImage
    var video: URL? = nil
    let location: GeoPoint
    let hint: String
    let message: String
    /// `nil` = every friend can find it.
    let recipientID: UUID?
}
