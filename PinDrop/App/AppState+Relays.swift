import Foundation
import SwiftUI

// MARK: - Relays (Staffetta)

extension AppState {
    /// Relays whose baton you hold right now, most urgent first.
    var myBatons: [Relay] {
        relays
            .filter { $0.isHeld(by: currentUser.id) }
            .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
    }

    /// Relays drawn on the map: active ones, and the ones that ended in the last day.
    var visibleRelays: [Relay] {
        relays.filter { relay in
            guard relay.legs.count >= 1 else { return false }
            if relay.status == .active { return true }
            return (relay.endedAt ?? .distantPast) > Date.now.addingTimeInterval(-86_400)
        }
    }

    func reloadRelays() async {
        guard sessionPhase == .ready, let fetched = try? await dataService.fetchRelays() else { return }
        if fetched != relays {
            withAnimation(Theme.spring) {
                relays = fetched
            }
        }
        if let shown = presentedRelay, let fresh = fetched.first(where: { $0.id == shown.id }), fresh != shown {
            presentedRelay = fresh
        }
    }

    func openRelay(_ relayID: UUID) {
        Task {
            await reloadRelays()
            if let relay = relays.first(where: { $0.id == relayID }) {
                presentedRelay = relay
                if let leg = relay.lastLeg {
                    focusMap(on: leg.location, spanMeters: max(1_500, relay.distance * 1.4))
                }
            }
        }
    }

    /// Opens the camera to run your leg of this relay.
    func runLeg(of relay: Relay) {
        presentedRelay = nil
        relayRun = relay
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            isCameraPresented = true
        }
    }

    /// Friends you can pass this relay's baton to (people who already ran a leg are excluded).
    func relayCandidates(for relay: Relay?) -> [UserProfile] {
        guard let relay else { return friends }
        return friends.filter { !relay.hasRun($0.id) }
    }

    /// Publishes the photo as a relay leg: a new relay, or your leg of the running one.
    func publishRelay(_ draft: RelayDraft, processed: ProcessedImage, location: GeoPoint, placeName: String?, caption: String) async throws {
        do {
            switch draft {
            case let .start(title, emoji, passTo):
                let relayID = try await dataService.startRelay(
                    title: title, emoji: emoji, image: processed, location: location,
                    placeName: placeName, caption: caption, passTo: passTo
                )
                let friend = friends.first { $0.id == passTo }
                showToast(.success, title: String(localized: "relay.toast.started.title"), subtitle: String(localized: "relay.toast.passed \(friend?.firstName ?? "")"))
                await reloadRelays()
                openRelayLater(relayID)
            case let .leg(relayID, passTo):
                try await dataService.runRelayLeg(
                    relayID: relayID, image: processed, location: location,
                    placeName: placeName, caption: caption, passTo: passTo
                )
                relayRun = nil
                if let passTo {
                    let friend = friends.first { $0.id == passTo }
                    showToast(.success, title: String(localized: "relay.toast.leg.title"), subtitle: String(localized: "relay.toast.passed \(friend?.firstName ?? "")"))
                } else {
                    showToast(.success, title: String(localized: "relay.toast.finished.title"), subtitle: String(localized: "relay.toast.finished.body"))
                }
                await reloadRelays()
                openRelayLater(relayID)
            }
            HapticManager.shared.success()
        } catch {
            throw RelayError(error)
        }
    }

    private func openRelayLater(_ relayID: UUID) {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if let relay = relays.first(where: { $0.id == relayID }) {
                presentedRelay = relay
                if let leg = relay.lastLeg {
                    focusMap(on: leg.location, spanMeters: max(1_500, relay.distance * 1.4))
                }
            }
        }
    }
}

/// Server errors of the relay functions, in words.
struct RelayError: LocalizedError {
    let message: String

    init(_ error: Error) {
        let text = String(describing: error)
        if text.contains("relay_too_close") {
            message = String(localized: "relay.error.tooClose \(LocaleFormatter.distance(meters: Relay.minimumLegDistance))")
        } else if text.contains("relay_already_ran") {
            message = String(localized: "relay.error.alreadyRan")
        } else if text.contains("relay_over") {
            message = String(localized: "relay.error.over")
        } else if text.contains("relay_not_holder") {
            message = String(localized: "relay.error.notHolder")
        } else if text.contains("relay_not_friend") {
            message = String(localized: "relay.error.notFriend")
        } else {
            message = error.localizedDescription
        }
    }

    var errorDescription: String? { message }
}
