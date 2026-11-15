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
