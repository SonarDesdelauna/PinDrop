import Foundation

/// A row of `public.friendships` with both profiles embedded.
struct Friendship: Identifiable, Decodable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case pending
        case accepted
    }

    let id: UUID
    let requesterID: UUID
    let addresseeID: UUID
    let status: Status
    let createdAt: Date
    let requester: UserProfile
    let addressee: UserProfile

    enum CodingKeys: String, CodingKey {
        case id
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case status
        case createdAt = "created_at"
        case requester
        case addressee
    }

    /// The other person in the friendship.
    func other(than userID: UUID) -> UserProfile {
        requesterID == userID ? addressee : requester
    }
}

/// Friends and pending requests of the signed-in user.
struct FriendsSnapshot: Sendable, Equatable {
    var friends: [UserProfile]
    var incoming: [Friendship]
    var outgoing: [Friendship]
    /// Friend user id → friendship id (used to remove a friend).
    var friendshipIDs: [UUID: UUID]

    static let empty = FriendsSnapshot(friends: [], incoming: [], outgoing: [], friendshipIDs: [:])

    init(friends: [UserProfile], incoming: [Friendship], outgoing: [Friendship], friendshipIDs: [UUID: UUID]) {
        self.friends = friends
        self.incoming = incoming
        self.outgoing = outgoing
        self.friendshipIDs = friendshipIDs
    }

    init(rows: [Friendship], currentUserID: UUID) {
        var friends: [UserProfile] = []
        var incoming: [Friendship] = []
        var outgoing: [Friendship] = []
        var ids: [UUID: UUID] = [:]
        for row in rows {
            switch row.status {
            case .accepted:
                let other = row.other(than: currentUserID)
                friends.append(other)
                ids[other.id] = row.id
            case .pending:
                if row.addresseeID == currentUserID {
                    incoming.append(row)
                } else {
                    outgoing.append(row)
                }
            }
        }
        friends.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        incoming.sort { $0.createdAt > $1.createdAt }
        outgoing.sort { $0.createdAt > $1.createdAt }
        self.init(friends: friends, incoming: incoming, outgoing: outgoing, friendshipIDs: ids)
    }
}

/// Result of `send_friend_request`.
enum FriendRequestResult: String, Decodable, Sendable {
    case requested
    case accepted
    case alreadyFriends = "already_friends"
    case alreadyRequested = "already_requested"
    case notFound = "not_found"
    case ownCode = "self"

    var message: String {
        switch self {
        case .requested: String(localized: "friends.add.result.requested")
        case .accepted: String(localized: "friends.add.result.accepted")
        case .alreadyFriends: String(localized: "friends.add.result.alreadyFriends")
        case .alreadyRequested: String(localized: "friends.add.result.alreadyRequested")
        case .notFound: String(localized: "friends.add.result.notFound")
        case .ownCode: String(localized: "friends.add.result.self")
        }
    }

    var isSuccess: Bool {
        self == .requested || self == .accepted
    }
}

/// An unseen "On my way" ping addressed to the signed-in user.
struct IncomingPing: Identifiable, Decodable, Sendable {
    let id: UUID
    let fromID: UUID
    let pinID: UUID?
    let etaSeconds: Int
    let createdAt: Date
    let sender: UserProfile

    enum CodingKeys: String, CodingKey {
        case id
        case fromID = "from_id"
        case pinID = "pin_id"
        case etaSeconds = "eta_seconds"
        case createdAt = "created_at"
        case sender
    }
}
