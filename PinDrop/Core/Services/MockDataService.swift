import SwiftUI
import UIKit

/// Everything demo mode adds on top of the real data, built around the user's real position,
/// so every new mechanic can be tried from home.
struct DemoScenario {
    var anchor: GeoPoint
    var friends: [UserProfile]
    var pins: [PhotoPin]
    /// Generated photos keyed by their fake storage paths.
    var images: [String: Data]
    var friendLocations: [UUID: FriendLocation]
    var onlineIDs: Set<UUID>
    var capsules: [GeoCapsule]
    var capsuleSecrets: [UUID: String]
    var crossPaths: [CrossPathEvent]
    var generatedCrossPaths: Int

    var pinIDs: Set<UUID> {
        Set(pins.map(\.id))
    }

    var capsuleIDs: Set<UUID> {
        Set(capsules.map(\.id))
    }
}

/// Builds the demo scenario: a friend's evening trail (200 m, 500 m, 900 m), a cross-path with
/// Giulia 15 m away, a Geo-Capsule 120 m away and Marco standing 20 m away for a Sync Shot.
/// Nothing here is sent to the server.
@MainActor
enum MockDataService {
    static let marcoID = UUID(uuidString: "D3E0A001-0000-4000-8000-00000000A001") ?? UUID()
    static let giuliaID = UUID(uuidString: "D3E0A001-0000-4000-8000-00000000A002") ?? UUID()
    static let alexID = UUID(uuidString: "D3E0A001-0000-4000-8000-00000000A003") ?? UUID()
    static let extraFriendIDs: [UUID] = [
        UUID(uuidString: "D3E0A001-0000-4000-8000-00000000A004") ?? UUID(),
        UUID(uuidString: "D3E0A001-0000-4000-8000-00000000A005") ?? UUID(),
        UUID(uuidString: "D3E0A001-0000-4000-8000-00000000A006") ?? UUID()
    ]
    private static let extraFriendNames: [(String, String, String)] = [
        ("Sofia Bianchi", "sofia.demo", "#EC4899"),
        ("Leo Ferrari", "leo.demo", "#06B6D4"),
        ("Nina Ricci", "nina.demo", "#EAB308")
    ]

    static func profile(id: UUID, name: String, username: String, colorHex: String, emoji: String) -> UserProfile {
        UserProfile(
            id: id,
            username: username,
            displayName: name,
            bio: "",
            statusEmoji: emoji,
            avatarColorHex: colorHex,
            avatarPath: nil,
            inviteCode: "PD-DEMO",
            isSetup: true
        )
    }

    static var marco: UserProfile {
        profile(id: marcoID, name: "Marco Rossi", username: "marco.demo", colorHex: "#10B981", emoji: "📸")
    }

    static var giulia: UserProfile {
        profile(id: giuliaID, name: "Giulia Conti", username: "giulia.demo", colorHex: "#F97316", emoji: "🍸")
    }

    static var alex: UserProfile {
        profile(id: alexID, name: "Alex Moretti", username: "alex.demo", colorHex: "#3B82F6", emoji: "🎧")
    }

    // MARK: - Scenario

    static func makeScenario(anchor: GeoPoint, currentUser: UserProfile, now: Date = .now) -> DemoScenario {
        var scenario = DemoScenario(
            anchor: anchor,
            friends: [marco, giulia, alex],
            pins: [],
            images: [:],
            friendLocations: [:],
            onlineIDs: [marcoID],
            capsules: [],
            capsuleSecrets: [:],
            crossPaths: [],
            generatedCrossPaths: 0
        )

        // Alex's evening: three pins joined chronologically (Neon Trail).
        let trail: [(Double, Double, TimeInterval, String, String, [UIColor])] = [
            (200, 60, 14_400, "🍕", "Pizza time", [UIColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 1), UIColor(red: 0.55, green: 0.10, blue: 0.30, alpha: 1)]),
            (500, 75, 9_000, "🎶", "Live music", [UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1), UIColor(red: 0.30, green: 0.10, blue: 0.55, alpha: 1)]),
            (900, 90, 3_600, "🌙", "Rooftop", [UIColor(red: 0.12, green: 0.10, blue: 0.35, alpha: 1), UIColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1)])
        ]
        for (distance, bearing, age, emoji, title, colors) in trail {
            addPin(
                to: &scenario,
                author: alex,
                at: point(from: anchor, meters: distance, bearing: bearing),
                createdAt: now.addingTimeInterval(-age),
                emoji: emoji,
                title: title,
                colors: colors
            )
        }

        // Cross-path: Giulia dropped a pin 15 m from you 70 minutes ago, you 45 minutes ago.
        addPin(
            to: &scenario,
            author: giulia,
            at: anchor.offsetBy(northMeters: 9, eastMeters: 12),
            createdAt: now.addingTimeInterval(-4_200),
            emoji: "🍸",
            title: "Aperitivo",
            colors: [UIColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 1), UIColor(red: 0.93, green: 0.28, blue: 0.60, alpha: 1)]
        )
        addPin(
            to: &scenario,
            author: currentUser,
            at: anchor,
            createdAt: now.addingTimeInterval(-2_700),
            emoji: "✨",
            title: String(localized: "demo.photo.you"),
            colors: [UIColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1), UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1)]
        )

        // Marco, 20 m away and online: the Sync Shot button shows up.
        let marcoPoint = point(from: anchor, meters: 20, bearing: 225)
        scenario.friendLocations[marcoID] = FriendLocation(
            userID: marcoID,
            latitude: marcoPoint.latitude,
            longitude: marcoPoint.longitude,
            updatedAt: now,
            permission: "always"
        )

        // A Geo-Capsule hidden by Giulia 120 m away.
        let capsuleID = UUID()
        let capsulePoint = point(from: anchor, meters: 120, bearing: 200)
        let fullPath = "demo/capsules/\(capsuleID.uuidString)/full.jpg"
        let thumbPath = "demo/capsules/\(capsuleID.uuidString)/thumb.jpg"
        if let photo = renderPhoto(
            emoji: "🎁",
            title: String(localized: "demo.capsule.photoTitle"),
            colors: [UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1), UIColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1)]
        ) {
            scenario.images[fullPath] = photo.fullData
            scenario.images[thumbPath] = photo.thumbnailData
        }
        scenario.capsules.append(GeoCapsule(
            id: capsuleID,
            author: giulia,
            recipientID: nil,
            latitude: capsulePoint.latitude,
            longitude: capsulePoint.longitude,
            hint: String(localized: "demo.capsule.hint"),
            imagePath: fullPath,
            thumbPath: thumbPath,
            createdAt: now.addingTimeInterval(-1_800),
            expiresAt: now.addingTimeInterval(GeoCapsule.lifetime - 1_800)
        ))
        scenario.capsuleSecrets[capsuleID] = String(localized: "demo.capsule.message")

        scenario.crossPaths = CrossPathsDetector.detectAll(in: scenario.pins, currentUserID: currentUser.id, now: now)
        return scenario
    }

    /// Creates a fresh cross-path with a demo friend near the given point, and returns it.
    @discardableResult
    static func addCrossPath(to scenario: inout DemoScenario, near center: GeoPoint, currentUser: UserProfile, now: Date = .now) -> CrossPathEvent? {
        let index = scenario.generatedCrossPaths % extraFriendIDs.count
        let (name, username, color) = extraFriendNames[index]
        let friend = profile(id: extraFriendIDs[index], name: name, username: username, colorHex: color, emoji: "👋")
        if !scenario.friends.contains(where: { $0.id == friend.id }) {
            scenario.friends.append(friend)
        }
        scenario.generatedCrossPaths += 1

        let emojis = ["☕️", "🛍️", "🌆", "🍦", "🎨"]
        let emoji = emojis[scenario.generatedCrossPaths % emojis.count]
        let friendPoint = point(from: center, meters: Double.random(in: 10...32), bearing: Double.random(in: 0..<360))
        let minutesAgo = Double(Int.random(in: 12...50))
        addPin(
            to: &scenario,
            author: friend,
            at: friendPoint,
            createdAt: now.addingTimeInterval(-minutesAgo * 60),
            emoji: emoji,
            title: friend.firstName,
            colors: [UIColor(Color(hexString: color)), UIColor(red: 0.12, green: 0.10, blue: 0.30, alpha: 1)]
        )
        guard let myPin = addPin(
            to: &scenario,
            author: currentUser,
            at: center,
            createdAt: now.addingTimeInterval(-60),
            emoji: "📍",
            title: String(localized: "demo.photo.you"),
            colors: [UIColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1), UIColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1)]
        ) else { return nil }

        let events = CrossPathsDetector.detect(newPin: myPin, among: scenario.pins, currentUserID: currentUser.id, now: now)
        guard let event = events.first(where: { $0.friend.id == friend.id }) else { return nil }
        scenario.crossPaths.removeAll { $0.id == event.id }
        scenario.crossPaths.insert(event, at: 0)
        return event
    }

    // MARK: - Demo Sync Shot

    /// Simulates the partner's point of view: your shot mirrored, tinted and labeled.
    nonisolated static func partnerShot(from processed: ProcessedImage, partnerName: String) -> ProcessedImage? {
        guard let source = UIImage(data: processed.fullData) else { return nil }
        let size = source.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: size.width, y: 0)
            cg.scaleBy(x: -1, y: 1)
            source.draw(in: CGRect(origin: .zero, size: size))
            cg.restoreGState()
            let label = NSAttributedString(
                string: "DEMO · \(partnerName)",
                attributes: [
                    .font: roundedFont(size: size.width * 0.035, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
            let labelSize = label.size()
            let pill = CGRect(x: size.width * 0.04, y: size.height * 0.04, width: labelSize.width + 40, height: labelSize.height + 20)
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pill.minX + 20, y: pill.minY + 10))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return ImageCompressor.process(data)
    }

    // MARK: - Photos

    /// A colorful placeholder photo with an emoji and a title, run through the real pipeline.
    nonisolated static func renderPhoto(emoji: String, title: String, colors: [UIColor]) -> ProcessedImage? {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var generator = SeededGenerator(seed: UInt64(abs(title.hashValue % 100_000)) + 7)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let cgColors = (colors.isEmpty ? [UIColor.purple, UIColor.black] : colors).map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            for _ in 0..<16 {
                let diameter = CGFloat.random(in: 60...260, using: &generator)
                let origin = CGPoint(
                    x: CGFloat.random(in: -40...size.width, using: &generator),
                    y: CGFloat.random(in: -40...size.height, using: &generator)
                )
                UIColor.white.withAlphaComponent(CGFloat.random(in: 0.04...0.14, using: &generator)).setFill()
                UIBezierPath(ovalIn: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))).fill()
            }
            let emojiText = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: 300)])
            let emojiSize = emojiText.size()
            emojiText.draw(at: CGPoint(x: (size.width - emojiSize.width) / 2, y: size.height * 0.38 - emojiSize.height / 2))
            let titleText = NSAttributedString(
                string: title,
                attributes: [.font: roundedFont(size: 72, weight: .heavy), .foregroundColor: UIColor.white]
            )
            let titleSize = titleText.size()
            titleText.draw(at: CGPoint(x: (size.width - titleSize.width) / 2, y: size.height * 0.66))
            let badge = NSAttributedString(
                string: "DEMO",
                attributes: [.font: roundedFont(size: 30, weight: .bold), .foregroundColor: UIColor.white.withAlphaComponent(0.7)]
            )
            badge.draw(at: CGPoint(x: 40, y: 40))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return ImageCompressor.process(data)
    }

    nonisolated private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Helpers

    @discardableResult
    private static func addPin(
        to scenario: inout DemoScenario,
        author: UserProfile,
        at location: GeoPoint,
        createdAt: Date,
        emoji: String,
        title: String,
        colors: [UIColor]
    ) -> PhotoPin? {
        guard let photo = renderPhoto(emoji: emoji, title: title, colors: colors) else { return nil }
        let id = UUID()
        let folder = "demo/\(author.id.uuidString)/\(id.uuidString)"
        let pin = PhotoPin(
            id: id,
            author: author,
            latitude: location.latitude,
            longitude: location.longitude,
            placeName: nil,
            caption: title,
            imagePath: "\(folder)/full.jpg",
            thumbPath: "\(folder)/thumb.jpg",
            blurPath: "\(folder)/blur.jpg",
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(PhotoPin.lifetime)
        )
        scenario.images[pin.imagePath] = photo.fullData
        scenario.images[pin.thumbPath] = photo.thumbnailData
        scenario.images[pin.blurPath] = photo.blurData
        scenario.pins.append(pin)
        return pin
    }

    /// A point at the given distance (meters) and compass bearing (degrees) from another.
    static func point(from origin: GeoPoint, meters: Double, bearing: Double) -> GeoPoint {
        let radians = bearing * Double.pi / 180
        return origin.offsetBy(northMeters: meters * cos(radians), eastMeters: meters * sin(radians))
    }
}

/// Small seeded random generator for the decorative bubbles of demo photos.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
