import Foundation
import Supabase

/// Everything needed to publish a new live drop.
struct PinDraft: Sendable {
    let image: ProcessedImage
    let location: GeoPoint
    let placeName: String?
    let caption: String
    /// Set when the pin is one half of a Sync Shot.
    var syncSessionID: UUID? = nil
}

enum DataServiceError: LocalizedError, Sendable, Equatable {
    case notSignedIn
    case usernameTaken
    case invalidPayload
    case network

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            String(localized: "error.data.notSignedIn")
        case .usernameTaken:
            String(localized: "profile.username.taken")
        case .invalidPayload:
            String(localized: "error.data.invalidPayload")
        case .network:
            String(localized: "error.data.network")
        }
    }
}

/// Supabase backend: profiles, friendships, pins (+ storage), reactions and pings.
/// Authorization is enforced server-side by Row Level Security.
final class SupabaseDataService: Sendable {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    private var pinsBucket: StorageFileApi {
        client.storage.from(SupabaseConfig.pinsBucket)
    }

    private var capsulesBucket: StorageFileApi {
        client.storage.from("capsules")
    }

    private var avatarsBucket: StorageFileApi {
        client.storage.from(SupabaseConfig.avatarsBucket)
    }

    func currentUserID() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            throw DataServiceError.notSignedIn
        }
    }

    private static func storageID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static var nowISO: String {
        ISO8601DateFormatter().string(from: .now)
    }

    // MARK: - Profile

    func currentProfile() async throws -> UserProfile {
        let uid = try await currentUserID()
        return try await client
            .from("profiles")
            .select()
            .eq("id", value: uid)
            .single()
            .execute()
            .value
    }

    func updateProfile(_ update: ProfileUpdate) async throws -> UserProfile {
        let uid = try await currentUserID()
        do {
            return try await client
                .from("profiles")
                .update(update)
                .eq("id", value: uid)
                .select()
                .single()
                .execute()
                .value
        } catch let error as PostgrestError where error.code == "23505" {
            throw DataServiceError.usernameTaken
        }
    }

    func isUsernameAvailable(_ username: String) async throws -> Bool {
        struct Row: Decodable { let id: UUID }
        let uid = try await currentUserID()
        let rows: [Row] = try await client
            .from("profiles")
            .select("id")
            .eq("username", value: username)
            .limit(1)
            .execute()
            .value
        return rows.allSatisfy { $0.id == uid }
    }

    /// Uploads a new avatar JPEG and returns its storage path.
    func uploadAvatar(_ data: Data) async throws -> String {
        let uid = try await currentUserID()
        let path = "\(Self.storageID(uid))/avatar-\(Int(Date.now.timeIntervalSince1970)).jpg"
        _ = try await avatarsBucket.upload(
            path,
            data: data,
            options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: true)
        )
        return path
    }

    func deleteAvatar(path: String) async {
        _ = try? await avatarsBucket.remove(paths: [path])
    }

    // MARK: - Friends

    func fetchFriends() async throws -> FriendsSnapshot {
        let uid = try await currentUserID()
        let rows: [Friendship] = try await client
            .from("friendships")
            .select("id, requester_id, addressee_id, status, created_at, requester:profiles!friendships_requester_id_fkey(*), addressee:profiles!friendships_addressee_id_fkey(*)")
            .execute()
            .value
        return FriendsSnapshot(rows: rows, currentUserID: uid)
    }

    func sendFriendRequest(to target: String) async throws -> FriendRequestResult {
        let raw: String = try await client
            .rpc("send_friend_request", params: ["target": target])
            .execute()
            .value
        return FriendRequestResult(rawValue: raw) ?? .notFound
    }

    func respondToFriendRequest(_ requestID: UUID, accept: Bool) async throws {
        struct Params: Encodable, Sendable {
            let request_id: UUID
            let accept: Bool
        }
        try await client
            .rpc("respond_friend_request", params: Params(request_id: requestID, accept: accept))
            .execute()
    }

    func removeFriendship(_ friendshipID: UUID) async throws {
        try await client
            .from("friendships")
            .delete()
            .eq("id", value: friendshipID)
            .execute()
    }

    // MARK: - Pins

    /// All live pins visible to the user (own + friends'), newest first.
    func fetchActivePins() async throws -> [PhotoPin] {
        try await client
            .from("pins")
            .select(PhotoPin.selectColumns)
            .gt("expires_at", value: Self.nowISO)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchPin(_ id: UUID) async throws -> PhotoPin {
        try await client
            .from("pins")
            .select(PhotoPin.selectColumns)
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }

    /// Downloads an image from the private `pins` bucket (subject to storage RLS).
    func loadImage(path: String) async throws -> Data {
        try await pinsBucket.download(path: path)
    }

    /// Uploads the three image variants, then inserts the pin row. The location in `draft`
    /// is the only location ever uploaded.
    func publishPin(_ draft: PinDraft) async throws -> PhotoPin {
        struct NewPin: Encodable, Sendable {
            let id: UUID
            let latitude: Double
            let longitude: Double
            let place_name: String?
            let caption: String
            let image_path: String
            let thumb_path: String
            let blur_path: String
            let sync_session_id: UUID?
        }

        let uid = try await currentUserID()
        let pinID = UUID()
        let folder = "\(Self.storageID(uid))/\(Self.storageID(pinID))"
        let fullPath = "\(folder)/full.jpg"
        let thumbPath = "\(folder)/thumb.jpg"
        let blurPath = "\(folder)/blur.jpg"
        let options = FileOptions(cacheControl: "21600", contentType: "image/jpeg", upsert: false)

        do {
            _ = try await pinsBucket.upload(fullPath, data: draft.image.fullData, options: options)
            _ = try await pinsBucket.upload(thumbPath, data: draft.image.thumbnailData, options: options)
            _ = try await pinsBucket.upload(blurPath, data: draft.image.blurData, options: options)

            let row = NewPin(
                id: pinID,
                latitude: draft.location.latitude,
                longitude: draft.location.longitude,
                place_name: draft.placeName.map { String($0.prefix(120)) },
                caption: String(draft.caption.prefix(40)),
                image_path: fullPath,
                thumb_path: thumbPath,
                blur_path: blurPath,
                sync_session_id: draft.syncSessionID
            )
            return try await client
                .from("pins")
                .insert(row)
                .select(PhotoPin.selectColumns)
                .single()
                .execute()
                .value
        } catch {
            _ = try? await pinsBucket.remove(paths: [fullPath, thumbPath, blurPath])
            throw error
        }
    }

    /// Adds the reaction if missing, removes it otherwise. Returns the refreshed pin.
    func toggleReaction(_ emoji: String, on pin: PhotoPin) async throws -> PhotoPin {
        struct NewReaction: Encodable, Sendable {
            let pin_id: UUID
            let emoji: String
        }
        let uid = try await currentUserID()
        if pin.hasReaction(emoji, from: uid) {
            try await client
                .from("reactions")
                .delete()
                .eq("pin_id", value: pin.id)
                .eq("user_id", value: uid)
                .eq("emoji", value: emoji)
                .execute()
        } else {
            try await client
                .from("reactions")
                .insert(NewReaction(pin_id: pin.id, emoji: emoji))
                .execute()
        }
        return try await fetchPin(pin.id)
    }

    // MARK: - Places

    func fetchPlaces() async throws -> [SavedPlace] {
        try await client
            .rpc("my_places")
            .execute()
            .value
    }

    func addPlace(name: String, emoji: String, at point: GeoPoint, isPublic: Bool, addedFrom: UUID?) async throws {
        struct NewPlace: Encodable, Sendable {
            let name: String
            let emoji: String
            let latitude: Double
            let longitude: Double
            let radius_m: Int
            let is_public: Bool
            let added_from: UUID?
        }
        try await client
            .from("places")
            .insert(NewPlace(
                name: String(name.prefix(40)),
                emoji: emoji,
                latitude: point.latitude,
                longitude: point.longitude,
                radius_m: SavedPlace.defaultRadius,
                is_public: isPublic,
                added_from: addedFrom
            ))
            .execute()
    }

    func updatePlace(_ id: UUID, name: String, emoji: String, isPublic: Bool) async throws {
        struct PlaceUpdate: Encodable, Sendable {
            let name: String
            let emoji: String
            let is_public: Bool
        }
        try await client
            .from("places")
            .update(PlaceUpdate(name: String(name.prefix(40)), emoji: emoji, is_public: isPublic))
            .eq("id", value: id)
            .execute()
    }

    /// Other people's public places around a point.
    func fetchPublicPlaces(near point: GeoPoint) async throws -> [PublicPlace] {
        struct Params: Encodable, Sendable {
            let lat: Double
            let lon: Double
            let radius_km: Double
        }
        return try await client
            .rpc("public_places_near", params: Params(lat: point.latitude, lon: point.longitude, radius_km: 30))
            .execute()
            .value
    }

    /// Public places of one user (shown on their profile).
    func fetchPublicPlaces(of userID: UUID) async throws -> [PlaceSummary] {
        try await client
            .from("places")
            .select(PlaceSummary.selectColumns)
            .eq("owner_id", value: userID)
            .eq("is_public", value: true)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Profiles & social

    func fetchProfile(_ id: UUID) async throws -> UserProfile {
        try await client
            .from("profiles")
            .select()
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }

    func fetchProfiles(_ ids: [UUID]) async throws -> [UserProfile] {
        guard !ids.isEmpty else { return [] }
        return try await client
            .from("profiles")
            .select()
            .in("id", values: ids)
            .execute()
            .value
    }

    /// Counts a view of someone's profile (max once per day) and returns their total.
    func recordProfileView(_ target: UUID) async throws -> Int {
        try await client
            .rpc("record_profile_view", params: ["target": target])
            .execute()
            .value
    }

    /// Shares the current position with the server (never with other users) to measure time
    /// spent with friends. Returns how many friends are with you.
    @discardableResult
    func heartbeat(at point: GeoPoint) async throws -> Int {
        struct Params: Encodable, Sendable {
            let lat: Double
            let lon: Double
        }
        return try await client
            .rpc("heartbeat", params: Params(lat: point.latitude, lon: point.longitude))
            .execute()
            .value
    }

    func fetchFriendTimes() async throws -> [FriendTime] {
        try await client
            .from("friend_time")
            .select("user_a, user_b, seconds, best_since")
            .execute()
            .value
    }

    // MARK: - Live location shared with friends

    /// Shares your position (when given) and your location permission with your friends.
    func reportLocation(_ point: GeoPoint?, permission: String) async throws {
        struct Params: Encodable, Sendable {
            let lat: Double?
            let lon: Double?
            let perm: String

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let lat { try container.encode(lat, forKey: .lat) } else { try container.encodeNil(forKey: .lat) }
                if let lon { try container.encode(lon, forKey: .lon) } else { try container.encodeNil(forKey: .lon) }
                try container.encode(perm, forKey: .perm)
            }

            enum CodingKeys: String, CodingKey {
                case lat
                case lon
                case perm
            }
        }
        try await client
            .rpc("report_location", params: Params(lat: point?.latitude, lon: point?.longitude, perm: permission))
            .execute()
    }

    func fetchFriendLocations() async throws -> [FriendLocation] {
        let uid = try await currentUserID()
        return try await client
            .from("live_locations")
            .select("user_id, latitude, longitude, updated_at, permission")
            .neq("user_id", value: uid)
            .execute()
            .value
    }

    func fetchLocationPermissions() async throws -> [LocationPermissionRow] {
        let uid = try await currentUserID()
        return try await client
            .from("location_permissions")
            .select("user_id, permission")
            .neq("user_id", value: uid)
            .execute()
            .value
    }

    // MARK: - Online presence & suggestions

    /// Marks the app as open (no position is sent).
    func touchPresence() async throws {
        try await client.rpc("touch_presence").execute()
    }

    func goOffline() async throws {
        try await client.rpc("go_offline").execute()
    }

    /// Friends with the app open right now.
    func fetchOnlineFriends() async throws -> [UUID] {
        try await client.rpc("friends_online").execute().value
    }

    func fetchSuggestions() async throws -> [SuggestionRow] {
        try await client.rpc("suggested_friends", params: ["lim": 20]).execute().value
    }

    // MARK: - Sync Shot

    /// Invites a friend nearby to a Sync Shot.
    func syncInvite(partner: UUID) async throws -> SyncSessionRow {
        try await client.rpc("sync_invite", params: ["partner": partner]).execute().value
    }

    func syncRespond(_ session: UUID, accept: Bool) async throws {
        struct Params: Encodable, Sendable {
            let session: UUID
            let accept: Bool
        }
        try await client.rpc("sync_respond", params: Params(session: session, accept: accept)).execute()
    }

    /// Starts the shared countdown (both phones shoot ~3.6 s later).
    func syncArm(_ session: UUID) async throws {
        try await client.rpc("sync_arm", params: ["session": session]).execute()
    }

    func syncCancel(_ session: UUID) async throws {
        try await client.rpc("sync_cancel", params: ["session": session]).execute()
    }

    func syncPoll(_ session: UUID) async throws -> SyncPollRow? {
        let rows: [SyncPollRow] = try await client.rpc("sync_poll", params: ["session": session]).execute().value
        return rows.first
    }

    /// Sync Shot invitations addressed to you in the last 2 minutes.
    func fetchPendingSyncInvites() async throws -> [SyncSessionRow] {
        let uid = try await currentUserID()
        let since = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-120))
        return try await client
            .from("sync_sessions")
            .select("id, initiator_id, partner_id, status, fire_at, created_at")
            .eq("partner_id", value: uid)
            .eq("status", value: "pending")
            .gt("created_at", value: since)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// The pins of a Sync Shot session (yours and your partner's).
    func fetchSyncPins(session: UUID) async throws -> [PhotoPin] {
        try await client
            .from("pins")
            .select(PhotoPin.selectColumns)
            .eq("sync_session_id", value: session)
            .execute()
            .value
    }

    // MARK: - Cross-paths

    /// Asks the server to re-check your live pins against your friends' ones.
    func detectCrossPaths() async throws {
        try await client.rpc("detect_cross_paths").execute()
    }

    func fetchCrossPaths() async throws -> [CrossPathRow] {
        let since = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-CrossPathEvent.lookback))
        return try await client
            .from("cross_paths")
            .select("id, user_a, user_b, pin_a, pin_b, latitude, longitude, distance_m, delta_seconds, created_at")
            .gt("created_at", value: since)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Geo-Capsules

    func fetchCapsules() async throws -> [GeoCapsule] {
        try await client
            .from("geo_capsules")
            .select(GeoCapsule.selectColumns)
            .gt("expires_at", value: Self.nowISO)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Your openings and the openings of your own capsules.
    func fetchCapsuleOpens() async throws -> [CapsuleOpenRow] {
        try await client
            .from("capsule_opens")
            .select("capsule_id, user_id, opened_at")
            .execute()
            .value
    }

    func fetchCapsuleSecret(_ capsuleID: UUID) async throws -> String? {
        let rows: [CapsuleSecret] = try await client
            .from("capsule_secrets")
            .select("capsule_id, message")
            .eq("capsule_id", value: capsuleID)
            .execute()
            .value
        return rows.first?.message
    }

    /// Uploads the photo and hides a new capsule at the given spot for 24 hours.
    func createCapsule(_ draft: CapsuleDraft) async throws -> GeoCapsule {
        struct NewCapsule: Encodable, Sendable {
            let id: UUID
            let latitude: Double
            let longitude: Double
            let hint: String
            let image_path: String
            let thumb_path: String
            let recipient_id: UUID?
        }
        struct NewSecret: Encodable, Sendable {
            let capsule_id: UUID
            let message: String
        }

        let uid = try await currentUserID()
        let capsuleID = UUID()
        let folder = "\(Self.storageID(uid))/\(Self.storageID(capsuleID))"
        let fullPath = "\(folder)/full.jpg"
        let thumbPath = "\(folder)/thumb.jpg"
        let options = FileOptions(cacheControl: "86400", contentType: "image/jpeg", upsert: false)

        do {
            _ = try await capsulesBucket.upload(fullPath, data: draft.image.fullData, options: options)
            _ = try await capsulesBucket.upload(thumbPath, data: draft.image.thumbnailData, options: options)
            let capsule: GeoCapsule = try await client
                .from("geo_capsules")
                .insert(NewCapsule(
                    id: capsuleID,
                    latitude: draft.location.latitude,
                    longitude: draft.location.longitude,
                    hint: String(draft.hint.prefix(GeoCapsule.hintLimit)),
                    image_path: fullPath,
                    thumb_path: thumbPath,
                    recipient_id: draft.recipientID
                ))
                .select(GeoCapsule.selectColumns)
                .single()
                .execute()
                .value
            try await client
                .from("capsule_secrets")
                .insert(NewSecret(capsule_id: capsuleID, message: String(draft.message.prefix(GeoCapsule.messageLimit))))
                .execute()
            return capsule
        } catch {
            _ = try? await capsulesBucket.remove(paths: [fullPath, thumbPath])
            throw error
        }
    }

    /// Opens a capsule: the server checks that you are within 20 m of it.
    func openCapsule(_ capsuleID: UUID, at point: GeoPoint) async throws -> Bool {
        struct Params: Encodable, Sendable {
            let capsule: UUID
            let lat: Double
            let lon: Double
        }
        return try await client
            .rpc("open_capsule", params: Params(capsule: capsuleID, lat: point.latitude, lon: point.longitude))
            .execute()
            .value
    }

    func deleteCapsule(_ capsule: GeoCapsule) async throws {
        try await client.from("geo_capsules").delete().eq("id", value: capsule.id).execute()
        _ = try? await capsulesBucket.remove(paths: [capsule.imagePath, capsule.thumbPath])
    }

    /// Downloads a capsule photo (readable by its author and whoever opened it).
    func loadCapsuleImage(path: String) async throws -> Data {
        try await capsulesBucket.download(path: path)
    }

    // MARK: - Notifications

    func fetchNotifications() async throws -> [AppNotification] {
        try await client
            .from("notifications")
            .select(AppNotification.selectColumns)
            .order("created_at", ascending: false)
            .limit(60)
            .execute()
            .value
    }

    func markNotificationsRead() async throws {
        let uid = try await currentUserID()
        try await client
            .from("notifications")
            .update(["read_at": Self.nowISO])
            .eq("user_id", value: uid)
            .is("read_at", value: nil)
            .execute()
    }

    func deleteNotification(_ id: UUID) async throws {
        try await client
            .from("notifications")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    // MARK: - Contacts

    func matchContacts(emailHashes: [String], phoneHashes: [String]) async throws -> [ContactMatch] {
        struct Params: Encodable, Sendable {
            let email_hashes: [String]
            let phone_hashes: [String]
        }
        return try await client
            .rpc("match_contacts", params: Params(email_hashes: Array(emailHashes.prefix(3_000)), phone_hashes: Array(phoneHashes.prefix(3_000))))
            .execute()
            .value
    }

    /// Stores the hash of your phone number so friends can find you from their contacts.
    func setPhoneHash(_ hash: String?) async throws {
        struct Row: Encodable, Sendable {
            let user_id: UUID
            let phone_hash: String?
            let updated_at: String

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(user_id, forKey: .user_id)
                if let phone_hash {
                    try container.encode(phone_hash, forKey: .phone_hash)
                } else {
                    try container.encodeNil(forKey: .phone_hash)
                }
                try container.encode(updated_at, forKey: .updated_at)
            }

            enum CodingKeys: String, CodingKey {
                case user_id
                case phone_hash
                case updated_at
            }
        }
        let uid = try await currentUserID()
        try await client
            .from("contact_info")
            .upsert(Row(user_id: uid, phone_hash: hash, updated_at: Self.nowISO), onConflict: "user_id")
            .execute()
    }

    func hasPhoneHash() async -> Bool {
        struct Row: Decodable { let phone_hash: String? }
        let rows: [Row] = (try? await client.from("contact_info").select("phone_hash").execute().value) ?? []
        return rows.first?.phone_hash != nil
    }

    func deletePlace(_ id: UUID) async throws {
        try await client
            .from("places")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    /// Extends or starts visits of saved places around `point`. Returns how many matched.
    @discardableResult
    func recordPresence(at point: GeoPoint) async throws -> Int {
        struct Params: Encodable, Sendable {
            let lat: Double
            let lon: Double
        }
        return try await client
            .rpc("record_presence", params: Params(lat: point.latitude, lon: point.longitude))
            .execute()
            .value
    }

    // MARK: - Pings

    func sendOnMyWayPing(to pin: PhotoPin, etaSeconds: TimeInterval) async throws {
        struct NewPing: Encodable, Sendable {
            let to_id: UUID
            let pin_id: UUID
            let eta_seconds: Int
        }
        let seconds = Int(min(86_400, max(0, etaSeconds.rounded())))
        try await client
            .from("pings")
            .insert(NewPing(to_id: pin.author.id, pin_id: pin.id, eta_seconds: seconds))
            .execute()
    }

    func fetchUnseenPings() async throws -> [IncomingPing] {
        let uid = try await currentUserID()
        return try await client
            .from("pings")
            .select("id, from_id, pin_id, eta_seconds, created_at, sender:profiles!pings_from_id_fkey(*)")
            .eq("to_id", value: uid)
            .is("seen_at", value: nil)
            .order("created_at", ascending: false)
            .limit(10)
            .execute()
            .value
    }

    func markPingsSeen(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await client
            .from("pings")
            .update(["seen_at": Self.nowISO])
            .in("id", values: ids)
            .execute()
    }
}
