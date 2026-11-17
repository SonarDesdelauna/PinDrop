import CoreLocation
import Foundation

/// Someone in a relay (runner, baton holder or whoever dropped it).
struct RelayPerson: Decodable, Hashable, Sendable {
    let id: UUID
    let username: String
    let displayName: String
    let avatarColor: String
    let avatarPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarPath = "avatar_path"
    }

    var profile: UserProfile {
        UserProfile(
            id: id,
            username: username,
            displayName: displayName,
            bio: "",
            statusEmoji: "",
            avatarColorHex: avatarColor,
            avatarPath: avatarPath,
            inviteCode: "",
            isSetup: true
        )
    }

    var firstName: String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }
}

/// One leg of a relay: a photo dropped by a runner somewhere.
struct RelayLeg: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let seq: Int
    let latitude: Double
    let longitude: Double
    let placeName: String?
    let caption: String
    let imagePath: String
    let thumbPath: String
    let createdAt: Date
    let runner: RelayPerson

    enum CodingKeys: String, CodingKey {
        case id, seq, latitude, longitude, caption, runner
        case placeName = "place_name"
        case imagePath = "image_path"
        case thumbPath = "thumb_path"
        case createdAt = "created_at"
    }

    var location: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        location.coordinate
    }

    /// Storage keys ("bucket/path") for the photo and its thumbnail.
    var imageKey: String { "relays/\(imagePath)" }
    var thumbKey: String { "relays/\(thumbPath)" }
}

/// The Relay (Staffetta): a chain of photos passed from friend to friend, 24 hours per leg.
struct Relay: Decodable, Identifiable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case active
        case broken
        case finished
    }

    /// Hours each runner has to run their leg.
    static let legHours = 24
    /// Minimum distance between two legs.
    static let minimumLegDistance: Double = 300
    static let titleLimit = 40
    static let emojiPalette = ["🏃", "🔥", "⚡️", "🌍", "🍕", "🎉", "🚲", "🌙"]

    let id: UUID
    let title: String
    let emoji: String
    let status: Status
    let createdBy: UUID
    let createdAt: Date
    let deadline: Date?
    let endedAt: Date?
    let holder: RelayPerson?
    let passedBy: UUID?
    let brokenBy: RelayPerson?
    let legs: [RelayLeg]

    enum CodingKeys: String, CodingKey {
        case id, title, emoji, status, deadline, holder, legs
        case createdBy = "created_by"
        case createdAt = "created_at"
        case endedAt = "ended_at"
        case passedBy = "passed_by"
        case brokenBy = "broken_by"
    }

    var lastLeg: RelayLeg? { legs.last }

    /// Total length of the line, leg to leg.
    var distance: Double {
        zip(legs, legs.dropFirst()).reduce(0) { total, pair in
            total + GeoClustering.haversineDistance(from: pair.0.location, to: pair.1.location)
        }
    }

    func isHeld(by userID: UUID) -> Bool {
        status == .active && holder?.id == userID
    }

    func hasRun(_ userID: UUID) -> Bool {
        legs.contains { $0.runner.id == userID }
    }
}

/// Starting a relay or running its next leg from the camera.
enum RelayDraft: Sendable, Equatable {
    case start(title: String, emoji: String, passTo: UUID)
    case leg(relayID: UUID, passTo: UUID?)
}
