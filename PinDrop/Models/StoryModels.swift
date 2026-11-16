import Foundation

/// Someone who watched one of your stories.
struct StoryView: Hashable, Sendable, Decodable {
    let viewerID: UUID
    let liked: Bool
    let viewedAt: Date
    let viewer: UserProfile?

    enum CodingKeys: String, CodingKey {
        case viewerID = "viewer_id"
        case liked
        case viewedAt = "viewed_at"
        case viewer
    }
}

/// A photo story that disappears 24 hours after it was taken (`public.stories`).
struct StoryItem: Identifiable, Hashable, Sendable, Decodable {
    static let selectColumns = "id, image_path, overlay_text, overlay_y, location_tag, created_at, expires_at, author:profiles!stories_author_id_fkey(*), views:story_views(viewer_id, liked, viewed_at, viewer:profiles!story_views_viewer_id_fkey(*))"
    static let lifetime: TimeInterval = 86_400

    let id: UUID
    let author: UserProfile
    /// Storage key "bucket/path" of the photo.
    let imageKey: String
    let createdAt: Date
    let expiresAt: Date
    let locationTag: String?
    let overlayText: String?
    /// Vertical position of the text pill (0 top → 1 bottom).
    let overlayY: Double
    let isCloseFriendsOnly: Bool
    var viewedByMe: Bool
    var likedByMe: Bool
    var views: [StoryView]

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case imagePath = "image_path"
        case overlayText = "overlay_text"
        case overlayY = "overlay_y"
        case locationTag = "location_tag"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case views
    }

    init(
        id: UUID = UUID(),
        author: UserProfile,
        imageKey: String,
        createdAt: Date,
        locationTag: String?,
        overlayText: String?,
        overlayY: Double = 0.75,
        viewedByMe: Bool = false,
        likedByMe: Bool = false,
        views: [StoryView] = []
    ) {
        self.id = id
        self.author = author
        self.imageKey = imageKey
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(Self.lifetime)
        self.locationTag = locationTag
        self.overlayText = overlayText
        self.overlayY = overlayY
        self.isCloseFriendsOnly = false
        self.viewedByMe = viewedByMe
        self.likedByMe = likedByMe
        self.views = views
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        author = try container.decode(UserProfile.self, forKey: .author)
        let path = try container.decode(String.self, forKey: .imagePath)
        imageKey = "stories/\(path)"
        let text = try container.decodeIfPresent(String.self, forKey: .overlayText) ?? ""
        overlayText = text.isEmpty ? nil : text
        overlayY = try container.decodeIfPresent(Double.self, forKey: .overlayY) ?? 0.75
        locationTag = try container.decodeIfPresent(String.self, forKey: .locationTag)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        views = try container.decodeIfPresent([StoryView].self, forKey: .views) ?? []
        isCloseFriendsOnly = false
        viewedByMe = false
        likedByMe = false
    }

    func isExpired(at date: Date = .now) -> Bool {
        expiresAt <= date
    }

    /// Views by other people (your own view of your story does not count).
    var otherViews: [StoryView] {
        views.filter { $0.viewerID != author.id }
    }
}

/// All the live stories of one person, oldest first.
struct UserStoryRing: Identifiable, Hashable, Sendable {
    let author: UserProfile
    var stories: [StoryItem]

    var id: UUID { author.id }

    var hasUnseenStories: Bool {
        stories.contains { !$0.viewedByMe }
    }

    /// Where to start watching: the first story not seen yet.
    var firstUnseenIndex: Int {
        stories.firstIndex { !$0.viewedByMe } ?? 0
    }
}
