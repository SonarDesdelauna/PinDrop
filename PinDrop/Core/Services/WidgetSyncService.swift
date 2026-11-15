import Foundation
import WidgetKit

// This file is compiled into BOTH targets. The payload model and the store are shared;
// the sync service (which depends on app models) is excluded from the widget extension
// through the `WIDGET_EXTENSION` compilation condition.

/// Shared App Group configuration.
enum AppGroup {
    static let identifier = "group.com.pindrop.app"
    static let widgetKind = "PinDropWidget"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Lightweight JSON payload shared with the widget through the App Group container.
struct WidgetPayload: Codable, Sendable, Equatable {
    struct PinEntry: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let authorName: String
        let initials: String
        let avatarColorHex: String
        let placeName: String?
        let caption: String
        let createdAt: Date
        let expiresAt: Date
        let distanceMeters: Double?
        let thumbnail: Data?

        /// `pindrop://pin/{pinID}`
        var deepLink: URL? {
            URL(string: "pindrop://pin/\(id)")
        }

        var firstName: String {
            authorName.split(separator: " ").first.map(String.init) ?? authorName
        }

        func remainingFraction(at date: Date) -> Double {
            let total = expiresAt.timeIntervalSince(createdAt)
            guard total > 0 else { return 0 }
            return min(1, max(0, expiresAt.timeIntervalSince(date) / total))
        }
    }

    var isUnlocked: Bool
    var activeFriendsCount: Int
    var ownPinCreatedAt: Date?
    var ownPinExpiresAt: Date?
    var entries: [PinEntry]
    var updatedAt: Date

    static let empty = WidgetPayload(
        isUnlocked: false,
        activeFriendsCount: 0,
        ownPinCreatedAt: nil,
        ownPinExpiresAt: nil,
        entries: [],
        updatedAt: .distantPast
    )

    /// Sample content for the widget gallery and placeholders.
    static var preview: WidgetPayload {
        let now = Date.now
        return WidgetPayload(
            isUnlocked: true,
            activeFriendsCount: 3,
            ownPinCreatedAt: now.addingTimeInterval(-3_600),
            ownPinExpiresAt: now.addingTimeInterval(18_000),
            entries: [
                PinEntry(
                    id: "00000000-0000-0000-0000-000000000001",
                    authorName: "Luca Moretti",
                    initials: "LM",
                    avatarColorHex: "#F97316",
                    placeName: "Navigli",
                    caption: "☕️",
                    createdAt: now.addingTimeInterval(-1_200),
                    expiresAt: now.addingTimeInterval(20_400),
                    distanceMeters: 350,
                    thumbnail: nil
                ),
                PinEntry(
                    id: "00000000-0000-0000-0000-000000000002",
                    authorName: "Sofía Herrera",
                    initials: "SH",
                    avatarColorHex: "#EC4899",
                    placeName: "Brera",
                    caption: "🎶",
                    createdAt: now.addingTimeInterval(-5_400),
                    expiresAt: now.addingTimeInterval(16_200),
                    distanceMeters: 1_200,
                    thumbnail: nil
                ),
                PinEntry(
                    id: "00000000-0000-0000-0000-000000000003",
                    authorName: "Camille Laurent",
                    initials: "CL",
                    avatarColorHex: "#06B6D4",
                    placeName: nil,
                    caption: "",
                    createdAt: now.addingTimeInterval(-12_000),
                    expiresAt: now.addingTimeInterval(9_600),
                    distanceMeters: 2_400,
                    thumbnail: nil
                )
            ],
            updatedAt: now
        )
    }

    func activeEntries(at date: Date) -> [PinEntry] {
        entries.filter { $0.expiresAt > date }
    }

    /// The map is unlocked only while the user's own drop is still alive.
    func isUnlocked(at date: Date) -> Bool {
        guard isUnlocked, let ownPinExpiresAt else { return false }
        return ownPinExpiresAt > date
    }

    func ownRemainingFraction(at date: Date) -> Double {
        guard let ownPinCreatedAt, let ownPinExpiresAt else { return 0 }
        let total = ownPinExpiresAt.timeIntervalSince(ownPinCreatedAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, ownPinExpiresAt.timeIntervalSince(date) / total))
    }

    /// Equality that ignores `updatedAt`, used to avoid needless timeline reloads.
    func hasSameContent(as other: WidgetPayload) -> Bool {
        isUnlocked == other.isUnlocked
            && activeFriendsCount == other.activeFriendsCount
            && ownPinCreatedAt == other.ownPinCreatedAt
            && ownPinExpiresAt == other.ownPinExpiresAt
            && entries == other.entries
    }
}

/// Reads and writes the payload JSON in the shared container.
enum WidgetStore {
    static let fileName = "widget-payload.json"

    static var fileURL: URL? {
        AppGroup.containerURL?.appending(path: fileName)
    }

    static func read() -> WidgetPayload? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }

    static func write(_ payload: WidgetPayload) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
    }
}

#if !WIDGET_EXTENSION
/// Serializes the current map state into the App Group and reloads the widget timelines.
@MainActor
final class WidgetSyncService {
    static let shared = WidgetSyncService()

    /// Maximum number of friend pins exported to the widget.
    private let maxEntries = 4
    private var lastWrittenPayload: WidgetPayload?

    private init() {}

    func sync(pins: [PhotoPin], thumbnails: [UUID: Data], currentUserID: UUID, isUnlocked: Bool, userLocation: GeoPoint?) {
        let now = Date.now
        let activePins = pins.filter { !$0.isExpired(at: now) }
        let ownPin = activePins
            .filter { $0.author.id == currentUserID }
            .max { $0.expiresAt < $1.expiresAt }
        let friendPins = activePins
            .filter { $0.author.id != currentUserID }
            .sorted { $0.createdAt > $1.createdAt }

        let entries = friendPins.prefix(maxEntries).map { pin in
            WidgetPayload.PinEntry(
                id: pin.id.uuidString,
                authorName: pin.author.displayName,
                initials: pin.author.initials,
                avatarColorHex: pin.author.avatarColorHex,
                placeName: pin.placeName,
                caption: pin.caption,
                createdAt: pin.createdAt,
                expiresAt: pin.expiresAt,
                distanceMeters: userLocation.map { GeoClustering.haversineDistance(from: $0, to: pin.location) },
                thumbnail: thumbnails[pin.id]
            )
        }

        let payload = WidgetPayload(
            isUnlocked: isUnlocked,
            activeFriendsCount: Set(friendPins.map(\.author.id)).count,
            ownPinCreatedAt: ownPin?.createdAt,
            ownPinExpiresAt: ownPin?.expiresAt,
            entries: Array(entries),
            updatedAt: now
        )

        if let lastWrittenPayload, lastWrittenPayload.hasSameContent(as: payload) {
            return
        }

        do {
            try WidgetStore.write(payload)
            lastWrittenPayload = payload
            WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
        } catch {
            lastWrittenPayload = nil
        }
    }

    /// Removes every user-specific entry from the widget (sign-out).
    func clear() {
        lastWrittenPayload = nil
        try? WidgetStore.write(.empty)
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
    }
}
#endif
