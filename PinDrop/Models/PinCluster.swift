import CoreLocation
import Foundation

/// A group of active pins. One pin = a regular map pin; two or more within 50 m = a Shared Hub.
struct PinCluster: Identifiable, Hashable, Sendable {
    /// Stable identifier derived from the member pin ids.
    let id: String
    let center: GeoPoint
    /// Members, newest first.
    let pins: [PhotoPin]
    var placeName: String?

    init(pins: [PhotoPin], center: GeoPoint, placeName: String? = nil) {
        self.id = pins.map(\.id.uuidString).sorted().joined(separator: "|")
        self.center = center
        self.pins = pins
        self.placeName = placeName ?? pins.lazy.compactMap(\.placeName).first
    }

    var coordinate: CLLocationCoordinate2D {
        center.coordinate
    }

    /// `true` when this cluster is a Shared Hub (2+ pins).
    var isHub: Bool {
        pins.count >= 2
    }

    var leadPin: PhotoPin? {
        pins.first
    }

    /// Distinct authors, preserving order.
    var authors: [UserProfile] {
        var seen = Set<UUID>()
        return pins.compactMap { pin in
            seen.insert(pin.author.id).inserted ? pin.author : nil
        }
    }

    func contains(pinID: UUID) -> Bool {
        pins.contains { $0.id == pinID }
    }
}
