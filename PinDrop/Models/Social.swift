import CoreLocation
import Foundation

/// A compact place embedded in other rows (notifications, profiles).
struct PlaceSummary: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let ownerID: UUID
    let name: String
    let emoji: String
    let latitude: Double
    let longitude: Double
    let radiusM: Int
    let isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case name
        case emoji
        case latitude
        case longitude
        case radiusM = "radius_m"
        case isPublic = "is_public"
    }

    static let selectColumns = "id, owner_id, name, emoji, latitude, longitude, radius_m, is_public"

    var location: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }
}

/// Someone else's public place shown on the map (`public_places_near`).
struct PublicPlace: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let ownerID: UUID
    let name: String
    let emoji: String
    let latitude: Double
    let longitude: Double
    let radiusM: Int
    let ownerDisplayName: String
    let ownerUsername: String
    let ownerAvatarColor: String
    let ownerAvatarPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case name
        case emoji
        case latitude
        case longitude
        case radiusM = "radius_m"
        case ownerDisplayName = "owner_display_name"
        case ownerUsername = "owner_username"
        case ownerAvatarColor = "owner_avatar_color"
        case ownerAvatarPath = "owner_avatar_path"
    }

    var location: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        location.coordinate
    }
}

/// An in-app notification (`public.notifications`).
struct AppNotification: Identifiable, Decodable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case friendRequest = "friend_request"
        case friendAccepted = "friend_accepted"
        case ping
        case placeReached = "place_reached"
        case bestFriend = "best_friend"
    }

    struct Payload: Decodable, Hashable, Sendable {
        let etaSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case etaSeconds = "eta_seconds"
        }
    }

    static let selectColumns = "id, kind, created_at, read_at, payload, actor:profiles!notifications_actor_id_fkey(*), place:places(\(PlaceSummary.selectColumns))"

    let id: UUID
    let kind: Kind
    let createdAt: Date
    let readAt: Date?
    let payload: Payload?
    let actor: UserProfile?
    let place: PlaceSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case createdAt = "created_at"
        case readAt = "read_at"
        case payload
        case actor
        case place
    }

    var isUnread: Bool {
        readAt == nil
    }
}

/// Time spent together with a friend (`public.friend_time`).
struct FriendTime: Decodable, Hashable, Sendable {
    let userA: UUID
    let userB: UUID
    let seconds: Int
    let bestSince: Date?

    enum CodingKeys: String, CodingKey {
        case userA = "user_a"
        case userB = "user_b"
        case seconds
        case bestSince = "best_since"
    }

    /// Two hours together make you best friends.
    static let bestFriendSeconds = 7_200

    var isBestFriend: Bool {
        bestSince != nil || seconds >= Self.bestFriendSeconds
    }

    func other(than userID: UUID) -> UUID {
        userA == userID ? userB : userA
    }
}

/// A row returned by `suggested_friends`.
struct SuggestionRow: Decodable, Hashable, Sendable {
    let profileID: UUID
    let mutualCount: Int
    let reason: String

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case mutualCount = "mutual_count"
        case reason
    }
}

/// A suggested friend with their profile.
struct FriendSuggestion: Identifiable, Hashable, Sendable {
    let profile: UserProfile
    let mutualCount: Int
    let isNearby: Bool

    var id: UUID { profile.id }
}

/// A row returned by `match_contacts`.
struct ContactMatch: Decodable, Hashable, Sendable {
    let matchedHash: String
    let profileID: UUID

    enum CodingKeys: String, CodingKey {
        case matchedHash = "matched_hash"
        case profileID = "profile_id"
    }
}
