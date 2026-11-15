import Foundation

/// A PinDrop user (the signed-in user or a friend), stored in `public.profiles`.
struct UserProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var username: String
    var displayName: String
    var bio: String
    var statusEmoji: String
    var avatarColorHex: String
    var avatarPath: String?
    var inviteCode: String
    var isSetup: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case bio
        case statusEmoji = "status_emoji"
        case avatarColorHex = "avatar_color"
        case avatarPath = "avatar_path"
        case inviteCode = "invite_code"
        case isSetup = "is_setup"
    }

    /// `@username`
    var handle: String {
        "@" + username
    }

    /// Up to two initials, used by avatar badges.
    var initials: String {
        let parts = displayName
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// First word of the display name ("Luca Moretti" → "Luca").
    var firstName: String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    var avatarURL: URL? {
        avatarPath.flatMap { SupabaseConfig.publicAvatarURL(path: $0) }
    }

    static let avatarPalette: [String] = [
        "#7C3AED", "#A855F7", "#10B981", "#F97316",
        "#EC4899", "#06B6D4", "#EAB308", "#3B82F6",
        "#EF4444", "#14B8A6", "#8B5CF6", "#F43F5E"
    ]

    static let statusEmojiPalette: [String] = [
        "", "😎", "☕️", "🎧", "📚", "🏃", "🍕", "🎉", "🌙", "✈️", "💼", "🎮"
    ]

    /// Usernames: 3–24 characters, lowercase letters, digits, dot and underscore.
    static func sanitizeUsername(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = folded.lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" }
        return String(allowed.prefix(24))
    }

    static func isValidUsername(_ value: String) -> Bool {
        (3...24).contains(value.count) && sanitizeUsername(value) == value
    }

    /// Used only until the real profile has been loaded.
    static let placeholder = UserProfile(
        id: UUID(),
        username: "pindrop",
        displayName: "PinDrop",
        bio: "",
        statusEmoji: "",
        avatarColorHex: "#7C3AED",
        avatarPath: nil,
        inviteCode: "PD-000000",
        isSetup: true
    )
}

/// Editable profile fields sent to `public.profiles`.
struct ProfileUpdate: Encodable, Sendable {
    var displayName: String
    var username: String
    var bio: String
    var statusEmoji: String
    var avatarColorHex: String
    var avatarPath: String?
    var isSetup: Bool

    init(profile: UserProfile) {
        displayName = profile.displayName
        username = profile.username
        bio = profile.bio
        statusEmoji = profile.statusEmoji
        avatarColorHex = profile.avatarColorHex
        avatarPath = profile.avatarPath
        isSetup = profile.isSetup
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case bio
        case statusEmoji = "status_emoji"
        case avatarColorHex = "avatar_color"
        case avatarPath = "avatar_path"
        case isSetup = "is_setup"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(username, forKey: .username)
        try container.encode(bio, forKey: .bio)
        try container.encode(statusEmoji, forKey: .statusEmoji)
        try container.encode(avatarColorHex, forKey: .avatarColorHex)
        // Explicit null so removing the photo clears the column.
        if let avatarPath {
            try container.encode(avatarPath, forKey: .avatarPath)
        } else {
            try container.encodeNil(forKey: .avatarPath)
        }
        try container.encode(isSetup, forKey: .isSetup)
    }
}
