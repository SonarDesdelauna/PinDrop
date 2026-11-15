import Foundation

/// Everything needed to publish a new live drop.
struct PinDraft: Sendable {
    let imageData: Data
    let thumbnailData: Data
    let location: GeoPoint
    let placeName: String?
    let caption: String
    let capturedAt: Date
}

enum DataServiceError: LocalizedError, Sendable, Equatable {
    case pinNotFound
    case invalidPayload
    case network

    var errorDescription: String? {
        switch self {
        case .pinNotFound:
            String(localized: "error.data.pinNotFound")
        case .invalidPayload:
            String(localized: "error.data.invalidPayload")
        case .network:
            String(localized: "error.data.network")
        }
    }
}

/// Backend abstraction. `MockDataService` implements it for the demo; a Supabase or Firebase
/// implementation only has to conform to this protocol to be dropped into `PinDropApp`.
protocol DataServiceProtocol: Sendable {
    /// The signed-in user.
    func loadCurrentUser() async throws -> UserProfile
    /// Updates the display name of the signed-in user.
    func updateDisplayName(_ name: String) async throws -> UserProfile
    /// The user's friends.
    func fetchFriends() async throws -> [UserProfile]
    /// All non-expired pins visible to the user (friends' and own).
    func fetchActivePins(around anchor: GeoPoint?) async throws -> [PhotoPin]
    /// Publishes a live drop. The location inside `draft` is the only location ever uploaded.
    func publishPin(_ draft: PinDraft) async throws -> PhotoPin
    /// Adds the reaction if the user has not reacted with `emoji` yet, removes it otherwise.
    func toggleReaction(_ emoji: String, on pinID: UUID) async throws -> PhotoPin
    /// Sends an "On my way" ping with the estimated walking time to the pin's author.
    func sendOnMyWayPing(to pin: PhotoPin, etaSeconds: TimeInterval) async throws
    /// Enables or disables the demo content (mock friends and pins).
    func setDemoMode(_ enabled: Bool) async
}
