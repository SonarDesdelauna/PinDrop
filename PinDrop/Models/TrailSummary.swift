import CoreLocation
import Foundation

/// One person's evening on the map: their live pins joined in chronological order.
struct NeonTrail: Identifiable, Hashable, Sendable {
    let user: UserProfile
    let isCurrentUser: Bool
    /// Pin positions, oldest first.
    let points: [GeoPoint]
    let pinIDs: [UUID]

    var id: UUID { user.id }

    var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    /// Builds a trail for every person with at least two live pins.
    static func trails(from pins: [PhotoPin], currentUserID: UUID) -> [NeonTrail] {
        let grouped = Dictionary(grouping: pins, by: \.author.id)
        return grouped.compactMap { authorID, authorPins in
            let ordered = authorPins.sorted { $0.createdAt < $1.createdAt }
            guard ordered.count >= 2, let author = ordered.first?.author else { return nil }
            return NeonTrail(
                user: author,
                isCurrentUser: authorID == currentUserID,
                points: ordered.map(\.location),
                pinIDs: ordered.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isCurrentUser != rhs.isCurrentUser { return !lhs.isCurrentUser }
            return lhs.user.id.uuidString < rhs.user.id.uuidString
        }
    }
}

/// Statistics of the user's evening, shown in the Recap sheet and on the exported story card.
struct TrailSummary: Hashable, Sendable {
    /// The user's pins of the session, oldest first.
    let pins: [PhotoPin]
    let distanceMeters: Double
    let spotCount: Int
    /// Friends met (shared hub or Sync Shot) or crossed ("Sfiorati").
    let friendsMet: [UserProfile]
    let startedAt: Date
    let endedAt: Date
    /// The path along the streets, when directions are available.
    var routePoints: [GeoPoint] = []

    var points: [GeoPoint] {
        routePoints.count >= 2 ? routePoints : pins.map(\.location)
    }

    var isEmpty: Bool {
        pins.isEmpty
    }

    var distanceText: String {
        guard distanceMeters >= 1 else { return LocaleFormatter.distance(meters: 0) }
        return LocaleFormatter.distance(meters: distanceMeters)
    }

    /// Computes the summary of the user's pins within the given time window.
    static func make(
        pins allPins: [PhotoPin],
        currentUserID: UUID,
        crossPaths: [CrossPathEvent],
        window: TimeInterval = 43_200,
        routePoints: [GeoPoint] = [],
        now: Date = .now
    ) -> TrailSummary {
        let cutoff = now.addingTimeInterval(-window)
        let mine = allPins
            .filter { $0.author.id == currentUserID && $0.createdAt >= cutoff }
            .sorted { $0.createdAt < $1.createdAt }

        var distance: Double = 0
        let path = routePoints.count >= 2 ? routePoints : mine.map(\.location)
        for index in path.indices.dropFirst() {
            distance += GeoClustering.haversineDistance(from: path[index - 1], to: path[index])
        }

        let spots = GeoClustering.cluster(mine).count

        var met: [UUID: UserProfile] = [:]
        let others = allPins.filter { $0.author.id != currentUserID }
        for pin in mine {
            for other in others where GeoClustering.haversineDistance(from: pin.location, to: other.location) <= GeoClustering.hubRadiusMeters
                && abs(other.createdAt.timeIntervalSince(pin.createdAt)) <= 3_600 {
                met[other.author.id] = other.author
            }
            if let partner = pin.syncPartnerProfile {
                met[partner.id] = partner
            }
        }
        let myPinIDs = Set(mine.map(\.id))
        for event in crossPaths where myPinIDs.contains(event.myPinID) {
            met[event.friend.id] = event.friend
        }

        return TrailSummary(
            pins: mine,
            distanceMeters: distance,
            spotCount: spots,
            friendsMet: met.values.sorted { $0.displayName < $1.displayName },
            startedAt: mine.first?.createdAt ?? now,
            endedAt: mine.last?.createdAt ?? now,
            routePoints: routePoints
        )
    }
}
