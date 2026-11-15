import Foundation

/// Haversine distance + single-linkage spatial clustering for "Shared Hubs".
enum GeoClustering {
    /// Mean Earth radius (IUGG), in meters.
    static let earthRadiusMeters: Double = 6_371_008.8
    /// Two or more active pins within this radius merge into a Shared Hub.
    static let hubRadiusMeters: Double = 50

    /// Great-circle distance between two points using the Haversine formula, in meters.
    static func haversineDistance(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = (b.latitude - a.latitude) * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180

        let sinLat = sin(deltaLat / 2)
        let sinLon = sin(deltaLon / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        let c = 2 * atan2(sqrt(min(1, h)), sqrt(max(0, 1 - h)))
        return earthRadiusMeters * c
    }

    /// Groups pins so that any pin within `radius` meters of another pin of the group belongs to it
    /// (single-linkage, union–find). Groups with one pin are returned as single-pin clusters.
    static func cluster(_ pins: [PhotoPin], radius: Double = hubRadiusMeters) -> [PinCluster] {
        guard !pins.isEmpty else { return [] }

        var parent = Array(pins.indices)

        func root(of index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        func union(_ first: Int, _ second: Int) {
            let rootA = root(of: first)
            let rootB = root(of: second)
            if rootA != rootB {
                parent[rootB] = rootA
            }
        }

        for i in pins.indices {
            for j in (i + 1)..<pins.count where haversineDistance(from: pins[i].location, to: pins[j].location) <= radius {
                union(i, j)
            }
        }

        var groups: [Int: [PhotoPin]] = [:]
        for index in pins.indices {
            groups[root(of: index), default: []].append(pins[index])
        }

        return groups.values
            .map { members in
                let sorted = members.sorted { $0.createdAt > $1.createdAt }
                return PinCluster(pins: sorted, center: centroid(of: sorted.map(\.location)))
            }
            .sorted { $0.id < $1.id }
    }

    /// Arithmetic centroid, accurate enough for points a few tens of meters apart.
    static func centroid(of points: [GeoPoint]) -> GeoPoint {
        guard !points.isEmpty else { return GeoPoint.fallback }
        let count = Double(points.count)
        let latitude = points.reduce(0) { $0 + $1.latitude } / count
        let longitude = points.reduce(0) { $0 + $1.longitude } / count
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}
