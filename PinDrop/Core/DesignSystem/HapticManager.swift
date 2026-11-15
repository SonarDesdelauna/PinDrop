import UIKit

/// Centralized haptic feedback. All feedback generators live on the main actor.
@MainActor
final class HapticManager {
    static let shared = HapticManager()

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let notification = UINotificationFeedbackGenerator()
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private init() {}

    /// Warms up the Taptic Engine to minimize latency for the next feedback.
    func prepare() {
        lightImpact.prepare()
        rigidImpact.prepare()
        notification.prepare()
        selectionFeedback.prepare()
    }

    /// Camera shutter.
    func shutter() {
        rigidImpact.impactOccurred(intensity: 1)
        rigidImpact.prepare()
    }

    /// Front/back camera flip.
    func cameraFlip() {
        mediumImpact.impactOccurred(intensity: 0.75)
    }

    /// Tap on a single photo pin.
    func pinTap() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Tap on a cluster hub.
    func clusterTap() {
        softImpact.impactOccurred(intensity: 0.9)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            self.lightImpact.impactOccurred(intensity: 0.6)
        }
    }

    /// The map unlocks after the user's first live drop.
    func mapUnlocked() {
        notification.notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            self.heavyImpact.impactOccurred(intensity: 0.8)
            try? await Task.sleep(for: .milliseconds(90))
            self.softImpact.impactOccurred(intensity: 0.6)
        }
    }

    /// Reaction sent on a pin.
    func reaction() {
        softImpact.impactOccurred(intensity: 1)
    }

    /// Generic light tap for buttons.
    func tap() {
        lightImpact.impactOccurred(intensity: 0.7)
    }

    /// Sync Shot countdown: each tick is stronger than the previous one (3 → 2 → 1).
    func countdownTick(_ remaining: Int) {
        switch remaining {
        case 3:
            lightImpact.impactOccurred(intensity: 0.55)
            lightImpact.prepare()
        case 2:
            mediumImpact.impactOccurred(intensity: 0.8)
            mediumImpact.prepare()
        default:
            heavyImpact.impactOccurred(intensity: 1)
            heavyImpact.prepare()
        }
    }

    /// Both phones shoot together.
    func syncFire() {
        rigidImpact.impactOccurred(intensity: 1)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            self.notification.notificationOccurred(.success)
        }
    }

    /// "Sfiorati": you crossed a friend's path.
    func crossPath() {
        softImpact.impactOccurred(intensity: 1)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            self.softImpact.impactOccurred(intensity: 0.7)
            try? await Task.sleep(for: .milliseconds(160))
            self.lightImpact.impactOccurred(intensity: 0.5)
        }
    }

    /// A Geo-Capsule opens: success, then a crescendo.
    func capsuleOpened() {
        notification.notificationOccurred(.success)
        Task { @MainActor in
            for intensity in [0.4, 0.6, 0.8, 1.0] {
                try? await Task.sleep(for: .milliseconds(110))
                self.heavyImpact.impactOccurred(intensity: intensity)
            }
        }
    }

    func selection() {
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
    }

    func success() {
        notification.notificationOccurred(.success)
    }

    func warning() {
        notification.notificationOccurred(.warning)
    }

    func error() {
        notification.notificationOccurred(.error)
    }
}
