import Foundation

/// Finds "Sfiorati": pins of two different people dropped less than 40 m apart, more than
/// 5 minutes apart in time, within the last 6 hours. The server runs the same rule on every
/// new pin and is the one that unlocks the photos; this local copy powers demo mode and turns
/// server rows into displayable events.
enum CrossPathsDetector {
    /// Compares a new pin with every other person's live pin of the last 6 hours.
    static func detect(
        newPin: PhotoPin,
        among pins: [PhotoPin],
        currentUserID: UUID,
        now: Date = .now
    ) -> [CrossPathEvent] {
        let cutoff = now.addingTimeInterval(-CrossPathEvent.lookback)
        guard newPin.createdAt >= cutoff, !newPin.isExpired(at: now) else { return [] }
        return pins.compactMap { other in
            guard other.id != newPin.id,
                  other.author.id != newPin.author.id,
                  other.createdAt >= cutoff,
                  !other.isExpired(at: now) else { return nil }
            if let session = newPin.syncSessionID, session == other.syncSessionID {
                return nil
            }
            let distance = GeoClustering.haversineDistance(from: newPin.location, to: other.location)
            let delta = abs(newPin.createdAt.timeIntervalSince(other.createdAt))
            guard distance < CrossPathEvent.maximumDistance, delta > CrossPathEvent.minimumTimeDelta else { return nil }
            let isMine = newPin.author.id == currentUserID
            let isOthers = other.author.id == currentUserID
            guard isMine || isOthers else { return nil }
            let myPin = isMine ? newPin : other
            let friendPin = isMine ? other : newPin
            return CrossPathEvent(
                id: stableID(myPin.id, friendPin.id),
                friend: friendPin.author,
                myPinID: myPin.id,
                friendPinID: friendPin.id,
                location: GeoPoint(
                    latitude: (myPin.latitude + friendPin.latitude) / 2,
                    longitude: (myPin.longitude + friendPin.longitude) / 2
                ),
                distanceMeters: distance,
                timeDelta: delta,
                detectedAt: now
            )
        }
    }

    /// Runs `detect` for every pin of the current user.
    static func detectAll(in pins: [PhotoPin], currentUserID: UUID, now: Date = .now) -> [CrossPathEvent] {
        var events: [UUID: CrossPathEvent] = [:]
        for pin in pins where pin.author.id == currentUserID {
            for event in detect(newPin: pin, among: pins, currentUserID: currentUserID, now: now) {
                events[event.id] = event
            }
        }
        return events.values.sorted { $0.detectedAt > $1.detectedAt }
    }

    /// Turns server rows into events, keeping only those whose friend is known.
    static func events(
        from rows: [CrossPathRow],
        currentUserID: UUID,
        profiles: [UUID: UserProfile]
    ) -> [CrossPathEvent] {
        rows.compactMap { row in
            let iAmA = row.userA == currentUserID
            guard iAmA || row.userB == currentUserID else { return nil }
            let friendID = iAmA ? row.userB : row.userA
            guard let friend = profiles[friendID] else { return nil }
            return CrossPathEvent(
                id: row.id,
                friend: friend,
                myPinID: iAmA ? row.pinA : row.pinB,
                friendPinID: iAmA ? row.pinB : row.pinA,
                location: GeoPoint(latitude: row.latitude, longitude: row.longitude),
                distanceMeters: row.distanceMeters,
                timeDelta: TimeInterval(row.deltaSeconds),
                detectedAt: row.createdAt
            )
        }
    }

    /// Same id for the same pair of pins, whichever side detects it.
    private static func stableID(_ first: UUID, _ second: UUID) -> UUID {
        let ordered = [first.uuidString, second.uuidString].sorted().joined()
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in ordered.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
