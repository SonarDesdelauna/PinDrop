import Foundation

/// A Sync Shot session between two friends (`public.sync_sessions`).
struct SyncSessionRow: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let initiatorID: UUID
    let partnerID: UUID
    let status: String
    let fireAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case initiatorID = "initiator_id"
        case partnerID = "partner_id"
        case status
        case fireAt = "fire_at"
        case createdAt = "created_at"
    }
}

/// Session state with the server clock (`sync_poll`), so both phones count down together.
struct SyncPollRow: Decodable, Sendable {
    let status: String
    let fireAt: Date?
    let serverNow: Date

    enum CodingKeys: String, CodingKey {
        case status
        case fireAt = "fire_at"
        case serverNow = "server_now"
    }
}

/// The Sync Shot studio being shown, and with whom.
struct SyncShotContext: Identifiable, Equatable, Sendable {
    /// The session id (a local id in demo mode).
    let id: UUID
    let partner: UserProfile
    let isInitiator: Bool
    let isDemo: Bool
}

/// A friend nearby asked you for a Sync Shot.
struct IncomingSyncInvite: Identifiable, Equatable, Sendable {
    let session: SyncSessionRow
    let from: UserProfile

    var id: UUID { session.id }
}
