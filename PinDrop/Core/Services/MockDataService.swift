import Foundation
import UIKit

/// Demo backend. Friends and their pins are generated around the user's real GPS position,
/// captions are localized in the device language, and the user's own drops are persisted on disk
/// so that the "Blur-to-Unlock" state survives relaunches (until the 6 h expiry).
@MainActor
final class MockDataService: DataServiceProtocol {
    private enum Keys {
        static let currentUser = "pindrop.currentUser"
        static let demoMode = "pindrop.demoMode"
    }

    /// Description of one demo drop, relative to the anchor.
    private struct DemoSeed {
        let friendIndex: Int
        let northMeters: Double
        let eastMeters: Double
        let ageMinutes: Double
        let symbol: String
        let topColor: UInt32
        let bottomColor: UInt32
        let caption: String
        let reactionEmojis: [String]
    }

    // MARK: Demo friends (stable identifiers so deep links keep working across refreshes)

    static let demoFriends: [UserProfile] = [
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A01") ?? UUID(), username: "Luca Moretti", handle: "@luca.m", avatarColorHex: "#F97316", avatarImageData: nil, inviteCode: "PD-LUCA42"),
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A02") ?? UUID(), username: "Sofía Herrera", handle: "@sofi.hr", avatarColorHex: "#EC4899", avatarImageData: nil, inviteCode: "PD-SOFI77"),
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A03") ?? UUID(), username: "Camille Laurent", handle: "@camille", avatarColorHex: "#06B6D4", avatarImageData: nil, inviteCode: "PD-CAMI19"),
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A04") ?? UUID(), username: "Jonas Becker", handle: "@jonasb", avatarColorHex: "#84CC16", avatarImageData: nil, inviteCode: "PD-JONA88"),
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A05") ?? UUID(), username: "Maya Chen", handle: "@mayac", avatarColorHex: "#EAB308", avatarImageData: nil, inviteCode: "PD-MAYA23"),
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A06") ?? UUID(), username: "Noah Williams", handle: "@noahw", avatarColorHex: "#3B82F6", avatarImageData: nil, inviteCode: "PD-NOAH51"),
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A07") ?? UUID(), username: "Inès Dubois", handle: "@ines.d", avatarColorHex: "#F43F5E", avatarImageData: nil, inviteCode: "PD-INES64"),
        UserProfile(id: UUID(uuidString: "6F1C2A7E-1B9D-4C55-9A31-0D3E6B8C1A08") ?? UUID(), username: "Matteo Rossi", handle: "@teo.rossi", avatarColorHex: "#14B8A6", avatarImageData: nil, inviteCode: "PD-TEO305")
    ]

    /// Demo drops. The first three are within 50 m of each other and form a Shared Hub.
    private static func demoSeeds() -> [DemoSeed] {
        [
            DemoSeed(friendIndex: 0, northMeters: 230, eastMeters: 180, ageMinutes: 22, symbol: "cup.and.saucer.fill", topColor: 0x7C2D12, bottomColor: 0xF97316, caption: String(localized: "demo.caption.espresso"), reactionEmojis: ["🔥", "😍"]),
            DemoSeed(friendIndex: 1, northMeters: 246, eastMeters: 196, ageMinutes: 48, symbol: "music.note", topColor: 0x831843, bottomColor: 0xEC4899, caption: String(localized: "demo.caption.liveSet"), reactionEmojis: ["🫶"]),
            DemoSeed(friendIndex: 2, northMeters: 218, eastMeters: 207, ageMinutes: 95, symbol: "camera.macro", topColor: 0x164E63, bottomColor: 0x06B6D4, caption: String(localized: "demo.caption.goldenHour"), reactionEmojis: ["😍", "👀", "🔥"]),
            DemoSeed(friendIndex: 3, northMeters: -640, eastMeters: 420, ageMinutes: 140, symbol: "figure.run", topColor: 0x365314, bottomColor: 0x84CC16, caption: String(localized: "demo.caption.run"), reactionEmojis: ["🔥"]),
            DemoSeed(friendIndex: 4, northMeters: 900, eastMeters: -750, ageMinutes: 260, symbol: "books.vertical.fill", topColor: 0x713F12, bottomColor: 0xEAB308, caption: String(localized: "demo.caption.study"), reactionEmojis: []),
            DemoSeed(friendIndex: 5, northMeters: -350, eastMeters: -1_200, ageMinutes: 330, symbol: "sun.max.fill", topColor: 0x1E3A8A, bottomColor: 0x3B82F6, caption: String(localized: "demo.caption.rooftop"), reactionEmojis: ["😂", "🫶"])
        ]
    }

    // MARK: State

    private var currentUser: UserProfile
    private var demoModeEnabled: Bool
    private var ownPins: [PhotoPin] = []
    private var demoPins: [PhotoPin] = []
    private var demoAnchor: GeoPoint?
    private let storageURL: URL?

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.currentUser),
           let stored = try? JSONDecoder().decode(UserProfile.self, from: data) {
            currentUser = stored
        } else {
            currentUser = UserProfile.makeLocalUser(named: "")
        }
        demoModeEnabled = defaults.object(forKey: Keys.demoMode) as? Bool ?? true
        storageURL = Self.makeStorageURL()
        ownPins = loadOwnPins()
        persistUser()
    }

    // MARK: DataServiceProtocol

    func loadCurrentUser() async throws -> UserProfile {
        currentUser
    }

    func updateDisplayName(_ name: String) async throws -> UserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return currentUser }
        currentUser.username = String(trimmed.prefix(32))
        currentUser.handle = UserProfile.makeHandle(from: currentUser.username)
        persistUser()
        ownPins = ownPins.map { pin in
            var updated = pin
            updated.author = currentUser
            return updated
        }
        persistOwnPins()
        return currentUser
    }

    func fetchFriends() async throws -> [UserProfile] {
        try await Task.sleep(for: .milliseconds(150))
        return demoModeEnabled ? Self.demoFriends : []
    }

    func fetchActivePins(around anchor: GeoPoint?) async throws -> [PhotoPin] {
        try await Task.sleep(for: .milliseconds(250))
        let now = Date.now
        let ownCountBefore = ownPins.count
        ownPins.removeAll { $0.isExpired(at: now) }
        if ownPins.count != ownCountBefore {
            persistOwnPins()
        }

        guard demoModeEnabled else { return ownPins }

        let effectiveAnchor = anchor ?? demoAnchor ?? ownPins.first?.location ?? GeoPoint.fallback
        let anchorMoved = demoAnchor.map { GeoClustering.haversineDistance(from: $0, to: effectiveAnchor) > 3_000 } ?? true
        let allExpired = demoPins.allSatisfy { $0.isExpired(at: now) }
        if anchorMoved || allExpired {
            demoPins = generateDemoPins(around: effectiveAnchor, now: now)
            demoAnchor = effectiveAnchor
        }
        demoPins.removeAll { $0.isExpired(at: now) }
        return demoPins + ownPins
    }

    func publishPin(_ draft: PinDraft) async throws -> PhotoPin {
        guard !draft.imageData.isEmpty, !draft.thumbnailData.isEmpty else {
            throw DataServiceError.invalidPayload
        }
        try await Task.sleep(for: .milliseconds(450))
        let pin = PhotoPin(
            author: currentUser,
            imageData: draft.imageData,
            thumbnailData: draft.thumbnailData,
            location: draft.location,
            placeName: draft.placeName,
            caption: draft.caption,
            createdAt: draft.capturedAt
        )
        ownPins.append(pin)
        persistOwnPins()
        return pin
    }

    func toggleReaction(_ emoji: String, on pinID: UUID) async throws -> PhotoPin {
        try await Task.sleep(for: .milliseconds(120))
        if let index = ownPins.firstIndex(where: { $0.id == pinID }) {
            ownPins[index] = toggled(emoji, in: ownPins[index])
            persistOwnPins()
            return ownPins[index]
        }
        if let index = demoPins.firstIndex(where: { $0.id == pinID }) {
            demoPins[index] = toggled(emoji, in: demoPins[index])
            return demoPins[index]
        }
        throw DataServiceError.pinNotFound
    }

    func sendOnMyWayPing(to pin: PhotoPin, etaSeconds: TimeInterval) async throws {
        guard !pin.isExpired() else { throw DataServiceError.pinNotFound }
        try await Task.sleep(for: .milliseconds(700))
    }

    func setDemoMode(_ enabled: Bool) async {
        demoModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.demoMode)
        if !enabled {
            demoPins = []
            demoAnchor = nil
        }
    }

    // MARK: Helpers

    private func toggled(_ emoji: String, in pin: PhotoPin) -> PhotoPin {
        var updated = pin
        if let existing = updated.reactions.firstIndex(where: { $0.emoji == emoji && $0.userID == currentUser.id }) {
            updated.reactions.remove(at: existing)
        } else {
            updated.reactions.append(Reaction(id: UUID(), emoji: emoji, userID: currentUser.id, createdAt: .now))
        }
        return updated
    }

    private func generateDemoPins(around anchor: GeoPoint, now: Date) -> [PhotoPin] {
        Self.demoSeeds().enumerated().compactMap { offset, seed in
            let friend = Self.demoFriends[seed.friendIndex]
            let createdAt = now.addingTimeInterval(-seed.ageMinutes * 60)
            let rawImage = Self.renderDemoPhoto(symbol: seed.symbol, topColor: seed.topColor, bottomColor: seed.bottomColor, seed: offset)
            guard let processed = ImageCompressor.process(rawImage) else { return nil }
            let reactions = seed.reactionEmojis.enumerated().map { index, emoji in
                Reaction(
                    id: UUID(),
                    emoji: emoji,
                    userID: Self.demoFriends[(seed.friendIndex + index + 1) % Self.demoFriends.count].id,
                    createdAt: createdAt.addingTimeInterval(Double(index + 1) * 90)
                )
            }
            return PhotoPin(
                author: friend,
                imageData: processed.fullData,
                thumbnailData: processed.thumbnailData,
                location: anchor.offsetBy(northMeters: seed.northMeters, eastMeters: seed.eastMeters),
                placeName: nil,
                caption: seed.caption,
                createdAt: createdAt,
                reactions: reactions
            )
        }
    }

    // MARK: Persistence

    private static func makeStorageURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appending(path: "PinDrop", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "own-pins.json")
    }

    private func loadOwnPins() -> [PhotoPin] {
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let pins = try? JSONDecoder().decode([PhotoPin].self, from: data) else {
            return []
        }
        let now = Date.now
        return pins.filter { !$0.isExpired(at: now) }
    }

    private func persistOwnPins() {
        guard let storageURL, let data = try? JSONEncoder().encode(ownPins) else { return }
        try? data.write(to: storageURL, options: [.atomic, .completeFileProtection])
    }

    private func persistUser() {
        guard let data = try? JSONEncoder().encode(currentUser) else { return }
        UserDefaults.standard.set(data, forKey: Keys.currentUser)
    }

    // MARK: Demo imagery (generated, never imported)

    private static func renderDemoPhoto(symbol: String, topColor: UInt32, bottomColor: UInt32, seed: Int) -> Data {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let top = uiColor(topColor)
        let bottom = uiColor(bottomColor)

        let image = renderer.image { context in
            let cgContext = context.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            let gradientColors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0, 1]) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            var generator = SeededGenerator(seed: UInt64(seed + 1) &* 2_654_435_761)
            for _ in 0..<16 {
                let radius = CGFloat.random(in: 40...200, using: &generator)
                let x = CGFloat.random(in: 0...size.width, using: &generator)
                let y = CGFloat.random(in: 0...size.height, using: &generator)
                let alpha = CGFloat.random(in: 0.04...0.2, using: &generator)
                cgContext.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
                cgContext.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }

            let configuration = UIImage.SymbolConfiguration(pointSize: 300, weight: .semibold)
            if let symbolImage = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(UIColor.white.withAlphaComponent(0.92), renderingMode: .alwaysOriginal) {
                let symbolSize = symbolImage.size
                let rect = CGRect(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2 - 40,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                symbolImage.draw(in: rect)
            }

            let vignetteColors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.5).cgColor] as CFArray
            if let vignette = CGGradient(colorsSpace: colorSpace, colors: vignetteColors, locations: [0, 1]) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                cgContext.drawRadialGradient(
                    vignette,
                    startCenter: center,
                    startRadius: size.width * 0.35,
                    endCenter: center,
                    endRadius: size.height * 0.75,
                    options: [.drawsAfterEndLocation]
                )
            }
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Deterministic SplitMix64 generator so demo imagery is stable between launches.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
