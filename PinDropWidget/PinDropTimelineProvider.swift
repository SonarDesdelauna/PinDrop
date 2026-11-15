import SwiftUI
import WidgetKit

/// One rendering of the widget at a given date.
struct PinDropEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload

    /// Friends' pins still alive at `date`.
    var activeEntries: [WidgetPayload.PinEntry] {
        payload.activeEntries(at: date)
    }

    var isUnlocked: Bool {
        payload.isUnlocked(at: date)
    }

    /// Friends still live at `date` (the payload count minus entries that expired since it was written).
    var liveFriendsCount: Int {
        let liveAuthors = Set(activeEntries.map(\.authorName)).count
        let expiredSinceWrite = payload.entries.count - activeEntries.count
        return max(0, max(liveAuthors, payload.activeFriendsCount - expiredSinceWrite))
    }
}

/// Reads the JSON payload written by the app into the App Group container and builds a timeline
/// that refreshes countdown rings every 15 minutes and at every pin expiry.
struct PinDropTimelineProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60
    private static let horizon: TimeInterval = 2 * 60 * 60

    func placeholder(in context: Context) -> PinDropEntry {
        PinDropEntry(date: .now, payload: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (PinDropEntry) -> Void) {
        let stored = WidgetStore.read()
        let payload: WidgetPayload
        if context.isPreview {
            payload = stored.flatMap { $0.entries.isEmpty ? nil : $0 } ?? .preview
        } else {
            payload = stored ?? .empty
        }
        completion(PinDropEntry(date: .now, payload: payload))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PinDropEntry>) -> Void) {
        let payload = WidgetStore.read() ?? .empty
        let now = Date.now
        let horizonEnd = now.addingTimeInterval(Self.horizon)

        var dates: Set<Date> = [now]
        var step = now.addingTimeInterval(Self.refreshInterval)
        while step <= horizonEnd {
            dates.insert(step)
            step = step.addingTimeInterval(Self.refreshInterval)
        }

        var expiries = payload.entries.map(\.expiresAt)
        if let ownExpiry = payload.ownPinExpiresAt {
            expiries.append(ownExpiry)
        }
        for expiry in expiries where expiry > now && expiry <= horizonEnd {
            dates.insert(expiry.addingTimeInterval(1))
        }

        let entries = dates.sorted().map { PinDropEntry(date: $0, payload: payload) }
        completion(Timeline(entries: entries, policy: .after(horizonEnd)))
    }
}
