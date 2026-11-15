import Foundation

/// A PinDrop user (the signed-in user or a friend).
struct UserProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var username: String
    var handle: String
    var avatarColorHex: String
    var avatarImageData: Data?
    var inviteCode: String

    /// Up to two initials, used by avatar badges.
    var initials: String {
        let parts = username
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// First word of the display name ("Luca Moretti" → "Luca").
    var firstName: String {
        username.split(separator: " ").first.map(String.init) ?? username
    }

    static let avatarPalette: [String] = [
        "#7C3AED", "#A855F7", "#10B981", "#F97316",
        "#EC4899", "#06B6D4", "#EAB308", "#3B82F6"
    ]

    /// Random, human-friendly invite code such as `PD-7K2X9Q` (no ambiguous characters).
    static func generateInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<6).map { _ in alphabet.randomElement() ?? "X" })
        return "PD-\(code)"
    }

    /// Builds a `@handle` from a display name.
    static func makeHandle(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = folded.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        return "@" + (allowed.isEmpty ? "me" : String(allowed.prefix(20)))
    }

    /// Creates the local profile on first launch.
    static func makeLocalUser(named name: String) -> UserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? String(localized: "profile.defaultName") : trimmed
        return UserProfile(
            id: UUID(),
            username: displayName,
            handle: makeHandle(from: displayName),
            avatarColorHex: avatarPalette.randomElement() ?? "#7C3AED",
            avatarImageData: nil,
            inviteCode: generateInviteCode()
        )
    }

    /// Used only until the data service has loaded the real profile.
    static let placeholder = UserProfile(
        id: UUID(),
        username: "PinDrop",
        handle: "@pindrop",
        avatarColorHex: "#7C3AED",
        avatarImageData: nil,
        inviteCode: "PD-000000"
    )
}
