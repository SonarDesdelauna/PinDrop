import Foundation

/// A conversation: 1-to-1, a group of friends, or a live chat opened from a map hub (24 h).
struct ChatThread: Identifiable, Hashable, Sendable, Decodable {
    enum ThreadType: String, Hashable, Sendable, Decodable {
        case direct
        case group
        case clusterLive = "cluster"
    }

    let id: UUID
    let type: ThreadType
    var title: String?
    var emoji: String
    var participants: [UserProfile]
    var lastMessage: ChatMessage?
    var unreadCount: Int
    let createdAt: Date
    let expiresAt: Date?
    /// Chat theme id (see `ChatTheme`).
    var theme: String = "default"

    var isEphemeral: Bool { expiresAt != nil }

    enum CodingKeys: String, CodingKey {
        case id
        case type = "kind"
        case title
        case emoji
        case participants
        case lastMessage = "last_message"
        case unreadCount = "unread_count"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case theme
    }

    init(
        id: UUID,
        type: ThreadType,
        title: String?,
        emoji: String = "",
        participants: [UserProfile],
        lastMessage: ChatMessage?,
        unreadCount: Int,
        createdAt: Date = .now,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.emoji = emoji
        self.participants = participants
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(ThreadType.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        participants = try container.decodeIfPresent([UserProfile].self, forKey: .participants) ?? []
        lastMessage = try container.decodeIfPresent(ChatMessage.self, forKey: .lastMessage)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? "default"
    }

    /// The other people in the chat (everyone but you).
    func others(excluding userID: UUID) -> [UserProfile] {
        participants.filter { $0.id != userID }
    }

    /// The group name, or the friend's name for a 1-to-1 chat.
    func displayTitle(for userID: UUID) -> String {
        if let title, !title.isEmpty {
            return emoji.isEmpty ? title : "\(emoji) \(title)"
        }
        let names = others(excluding: userID).map(\.firstName)
        return names.isEmpty ? "PinDrop" : names.joined(separator: ", ")
    }

    var lastActivity: Date {
        lastMessage?.sentAt ?? createdAt
    }
}

/// One emoji reaction on a message.
struct ChatReaction: Hashable, Sendable, Decodable {
    let userID: UUID
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case emoji
    }
}

/// What a message carries.
enum MessageContent: Hashable, Sendable {
    case text(String)
    /// A photo taken in the chat (`attachmentKey` = "bucket/path").
    case livePhoto(attachmentKey: String, caption: String?)
    /// A reply to a pin on the map or to a story, with its preview.
    case pinReply(refID: UUID?, attachmentKey: String?, placeName: String, text: String, isStory: Bool)
    /// Your position or "on my way" with an ETA.
    case locationPing(latitude: Double, longitude: Double, placeName: String, etaMinutes: Int?)
    /// A voice message (`attachmentKey` = "chat/path.m4a"), with its length and waveform levels 0…1.
    case voice(attachmentKey: String, durationMs: Int, levels: [Double])
    /// Someone changed the chat theme.
    case themeChange(String)
}

/// A message in a conversation (`public.chat_messages`).
struct ChatMessage: Identifiable, Hashable, Sendable, Decodable {
    enum Kind: String, Hashable, Sendable, Decodable {
        case text
        case photo
        case pinReply = "pin_reply"
        case storyReply = "story_reply"
        case location
        case voice
        case theme
    }

    static let selectColumns = "id, thread_id, sender_id, kind, body, attachment_bucket, attachment_path, ref_id, place_name, latitude, longitude, eta_minutes, duration_ms, waveform, created_at, reactions:chat_reactions(user_id, emoji)"

    let id: UUID
    let threadID: UUID
    let senderID: UUID
    let kind: Kind
    let body: String
    let attachmentBucket: String?
    let attachmentPath: String?
    let refID: UUID?
    let placeName: String?
    let latitude: Double?
    let longitude: Double?
    let etaMinutes: Int?
    let durationMs: Int?
    let waveform: String?
    let sentAt: Date
    var reactions: [ChatReaction]

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "thread_id"
        case senderID = "sender_id"
        case kind
        case body
        case attachmentBucket = "attachment_bucket"
        case attachmentPath = "attachment_path"
        case refID = "ref_id"
        case placeName = "place_name"
        case latitude
        case longitude
        case etaMinutes = "eta_minutes"
        case durationMs = "duration_ms"
        case waveform
        case sentAt = "created_at"
        case reactions
    }

    init(
        id: UUID = UUID(),
        threadID: UUID,
        senderID: UUID,
        kind: Kind,
        body: String,
        attachmentBucket: String? = nil,
        attachmentPath: String? = nil,
        refID: UUID? = nil,
        placeName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        etaMinutes: Int? = nil,
        durationMs: Int? = nil,
        waveform: String? = nil,
        sentAt: Date = .now,
        reactions: [ChatReaction] = []
    ) {
        self.id = id
        self.threadID = threadID
        self.senderID = senderID
        self.kind = kind
        self.body = body
        self.attachmentBucket = attachmentBucket
        self.attachmentPath = attachmentPath
        self.refID = refID
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.etaMinutes = etaMinutes
        self.durationMs = durationMs
        self.waveform = waveform
        self.sentAt = sentAt
        self.reactions = reactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        threadID = try container.decode(UUID.self, forKey: .threadID)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        kind = try container.decode(Kind.self, forKey: .kind)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        attachmentBucket = try container.decodeIfPresent(String.self, forKey: .attachmentBucket)
        attachmentPath = try container.decodeIfPresent(String.self, forKey: .attachmentPath)
        refID = try container.decodeIfPresent(UUID.self, forKey: .refID)
        placeName = try container.decodeIfPresent(String.self, forKey: .placeName)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        etaMinutes = try container.decodeIfPresent(Int.self, forKey: .etaMinutes)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        waveform = try container.decodeIfPresent(String.self, forKey: .waveform)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        reactions = try container.decodeIfPresent([ChatReaction].self, forKey: .reactions) ?? []
    }

    /// "bucket/path" of the attached image, used as the image cache key.
    var attachmentKey: String? {
        guard let attachmentBucket, let attachmentPath else { return nil }
        return "\(attachmentBucket)/\(attachmentPath)"
    }

    var content: MessageContent {
        switch kind {
        case .text:
            return .text(body)
        case .photo:
            return .livePhoto(attachmentKey: attachmentKey ?? "", caption: body.isEmpty ? nil : body)
        case .pinReply, .storyReply:
            return .pinReply(refID: refID, attachmentKey: attachmentKey, placeName: placeName ?? "", text: body, isStory: kind == .storyReply)
        case .location:
            return .locationPing(latitude: latitude ?? 0, longitude: longitude ?? 0, placeName: placeName ?? "", etaMinutes: etaMinutes)
        case .voice:
            return .voice(attachmentKey: attachmentKey ?? "", durationMs: durationMs ?? 0, levels: Self.levels(from: waveform))
        case .theme:
            return .themeChange(body)
        }
    }

    /// "0371…" → [0, 0.33, 0.77, 0.11, …]
    static func levels(from waveform: String?) -> [Double] {
        let digits = (waveform ?? "").compactMap { $0.wholeNumberValue }
        guard !digits.isEmpty else { return Array(repeating: 0.35, count: 28) }
        return digits.map { Double($0) / 9 }
    }

    /// [0…1] → "0371…" (at most 40 samples).
    static func waveform(from levels: [Double]) -> String {
        guard !levels.isEmpty else { return "" }
        let count = min(40, levels.count)
        var out = ""
        for i in 0..<count {
            let start = i * levels.count / count
            let end = max(start + 1, (i + 1) * levels.count / count)
            let slice = levels[start..<min(end, levels.count)]
            let value = slice.max() ?? 0
            out += String(Int((min(1, max(0, value)) * 9).rounded()))
        }
        return out
    }

    /// Reactions grouped as emoji → people who reacted.
    var reactionMap: [String: [UUID]] {
        var map: [String: [UUID]] = [:]
        for reaction in reactions {
            map[reaction.emoji, default: []].append(reaction.userID)
        }
        return map
    }
}

/// A message being sent (the server fills id, sender and date).
struct OutgoingMessage: Sendable {
    var kind: ChatMessage.Kind
    var body: String = ""
    var attachmentBucket: String?
    var attachmentPath: String?
    var refID: UUID?
    var placeName: String?
    var latitude: Double?
    var longitude: Double?
    var etaMinutes: Int?
    /// A photo to upload to the chat bucket first.
    var photo: Data?
    /// A voice message (m4a) to upload to the chat bucket first.
    var voice: Data?
    var durationMs: Int?
    var waveform: String?
}
