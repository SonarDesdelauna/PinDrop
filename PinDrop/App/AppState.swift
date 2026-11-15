import Observation
import SwiftUI

/// What the Stories-style viewer is currently showing.
struct ViewerSelection: Identifiable, Equatable {
    let id: String
    let pinIDs: [UUID]
    let startIndex: Int
}

/// A one-off request to move the map camera.
struct CameraTarget: Equatable {
    let point: GeoPoint
    let spanMeters: Double
    let token = UUID()
}

/// Transient banner shown at the top of the map.
struct ToastMessage: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case info
        case ping
        case warning
    }

    let id = UUID()
    let style: Style
    let title: String
    let subtitle: String?

    var systemImage: String {
        switch style {
        case .success: "sparkles"
        case .info: "info.circle.fill"
        case .ping: "figure.walk.motion"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

/// Global observable state: current user, pins, clusters, unlock state, selection and routing.
@MainActor
@Observable
final class AppState {
    private enum Keys {
        static let demoMode = "pindrop.demoMode"
    }

    private(set) var currentUser: UserProfile = .placeholder
    private(set) var friends: [UserProfile] = []
    private(set) var pins: [PhotoPin] = []
    private(set) var clusters: [PinCluster] = []
    private(set) var placeNames: [String: String] = [:]
    private(set) var userLocation: GeoPoint?
    private(set) var isRefreshing = false
    private(set) var hasLoadedOnce = false
    private(set) var cameraTarget: CameraTarget?
    private(set) var toast: ToastMessage?
    private(set) var isDemoModeEnabled: Bool
    var viewerSelection: ViewerSelection?
    var isCameraPresented = false
    var isFriendsDrawerPresented = false

    let dataService: any DataServiceProtocol
    let locationService: LocationService

    @ObservationIgnored private var hasBootstrapped = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var placeLookupsInFlight: Set<String> = []
    @ObservationIgnored private var pendingFocus: (pinID: UUID, openViewer: Bool)?

    init(dataService: any DataServiceProtocol, locationService: LocationService) {
        self.dataService = dataService
        self.locationService = locationService
        self.isDemoModeEnabled = UserDefaults.standard.object(forKey: Keys.demoMode) as? Bool ?? true
    }

    // MARK: - Derived state

    /// Pins that have not expired yet.
    var activePins: [PhotoPin] {
        let now = Date.now
        return pins.filter { !$0.isExpired(at: now) }
    }

    /// The user's most recent live drop, if any.
    var ownActivePin: PhotoPin? {
        let now = Date.now
        return pins
            .filter { $0.author.id == currentUser.id && !$0.isExpired(at: now) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Reciprocity: friends' pins are visible only while the user has a live drop.
    var isUnlocked: Bool {
        ownActivePin != nil
    }

    var friendActivePins: [PhotoPin] {
        activePins.filter { $0.author.id != currentUser.id }
    }

    /// Number of friend pins currently hidden behind the blur.
    var lockedFriendPinCount: Int {
        isUnlocked ? 0 : friendActivePins.count
    }

    /// Distinct friends with a live drop.
    var activeFriendsCount: Int {
        Set(friendActivePins.map(\.author.id)).count
    }

    func isOwn(_ pin: PhotoPin) -> Bool {
        pin.author.id == currentUser.id
    }

    func isLocked(_ pin: PhotoPin) -> Bool {
        !isUnlocked && !isOwn(pin)
    }

    func activePin(for friend: UserProfile) -> PhotoPin? {
        activePins
            .filter { $0.author.id == friend.id }
            .max { $0.createdAt < $1.createdAt }
    }

    func placeName(for cluster: PinCluster) -> String? {
        placeNames[cluster.id] ?? cluster.placeName
    }

    func placeName(for pin: PhotoPin) -> String? {
        if let name = pin.placeName {
            return name
        }
        if let name = placeNames[pin.id.uuidString] {
            return name
        }
        return clusters.first { $0.contains(pinID: pin.id) }.flatMap { placeNames[$0.id] }
    }

    /// Locale-formatted distance from the last known position (never uploaded).
    func distanceText(to point: GeoPoint) -> String? {
        guard let userLocation else { return nil }
        return LocaleFormatter.distance(meters: GeoClustering.haversineDistance(from: userLocation, to: point))
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        HapticManager.shared.prepare()
        do {
            currentUser = try await dataService.loadCurrentUser()
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
        await dataService.setDemoMode(isDemoModeEnabled)
        await refresh()
        startHousekeeping()
    }

    /// Reloads friends and pins. Concurrent calls are coalesced into one extra pass.
    func refresh() async {
        guard hasBootstrapped else { return }
        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        repeat {
            refreshQueued = false
            await loadContent()
        } while refreshQueued
        isRefreshing = false
    }

    private func loadContent() async {
        if locationService.isAuthorized, let fix = await locationService.currentLocation(maximumAge: 120) {
            userLocation = fix
        }
        let anchor = userLocation
        do {
            let fetchedFriends = try await dataService.fetchFriends()
            let fetchedPins = try await dataService.fetchActivePins(around: anchor)
            let now = Date.now
            withAnimation(Theme.spring) {
                friends = fetchedFriends
                pins = fetchedPins
                    .filter { !$0.isExpired(at: now) }
                    .sorted { $0.createdAt > $1.createdAt }
                recomputeClusters()
            }
            hasLoadedOnce = true
            closeViewerIfNeeded()
            resolveMissingPlaceNames()
            syncWidget()
            resolvePendingFocus(dropIfMissing: true)
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    /// Refreshes the local position used for distance labels (one-shot, not shared).
    func refreshUserLocation() async {
        guard locationService.isAuthorized else { return }
        if let fix = await locationService.currentLocation(maximumAge: 15) {
            userLocation = fix
            syncWidget()
        }
    }

    private func startHousekeeping() {
        housekeepingTask?.cancel()
        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.pruneExpiredPins()
            }
        }
    }

    /// Removes pins whose 6 h lifetime is over. Re-locks the map when the user's own drop expires.
    func pruneExpiredPins() {
        let now = Date.now
        let active = pins.filter { !$0.isExpired(at: now) }
        if active.count != pins.count {
            withAnimation(Theme.spring) {
                pins = active
                recomputeClusters()
            }
            closeViewerIfNeeded()
        }
        syncWidget()
    }

    private func closeViewerIfNeeded() {
        guard let selection = viewerSelection else { return }
        let liveIDs = Set(pins.map(\.id))
        if !selection.pinIDs.contains(where: { liveIDs.contains($0) }) {
            viewerSelection = nil
        }
    }

    // MARK: - Actions

    /// Publishes a live drop. If the map was locked, it unlocks instantly with an animation.
    func publish(processed: ProcessedImage, location: GeoPoint, placeName: String?, caption: String, capturedAt: Date) async throws {
        let wasLocked = !isUnlocked
        let draft = PinDraft(
            imageData: processed.fullData,
            thumbnailData: processed.thumbnailData,
            location: location,
            placeName: placeName,
            caption: String(caption.prefix(40)),
            capturedAt: capturedAt
        )
        let pin = try await dataService.publishPin(draft)
        userLocation = location
        withAnimation(Theme.spring) {
            pins.removeAll { $0.id == pin.id }
            pins.insert(pin, at: 0)
            recomputeClusters()
        }
        resolveMissingPlaceNames()
        syncWidget()

        if wasLocked {
            HapticManager.shared.mapUnlocked()
            let unlockedCount = friendActivePins.count
            showToast(
                .success,
                title: String(localized: "toast.unlocked.title"),
                subtitle: String(localized: "toast.unlocked.subtitle \(unlockedCount)")
            )
        } else {
            HapticManager.shared.success()
            showToast(.success, title: String(localized: "toast.dropped.title"), subtitle: String(localized: "toast.dropped.subtitle"))
        }
        cameraTarget = CameraTarget(point: location, spanMeters: 1_800)
    }

    func toggleReaction(_ emoji: String, on pinID: UUID) async {
        HapticManager.shared.reaction()
        do {
            let updated = try await dataService.toggleReaction(emoji, on: pinID)
            replacePin(updated)
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    func sendOnMyWay(to pin: PhotoPin, etaSeconds: TimeInterval) async throws {
        try await dataService.sendOnMyWayPing(to: pin, etaSeconds: etaSeconds)
        HapticManager.shared.success()
        let duration = LocaleFormatter.walkingDuration(seconds: etaSeconds)
        let friendName = pin.author.firstName
        let myName = currentUser.firstName
        showToast(
            .ping,
            title: String(localized: "toast.ping.title \(friendName)"),
            subtitle: String(localized: "eta.preview \(myName) \(duration)")
        )
    }

    func updateDisplayName(_ name: String) async {
        do {
            let updated = try await dataService.updateDisplayName(name)
            currentUser = updated
            pins = pins.map { pin in
                guard pin.author.id == updated.id else { return pin }
                var copy = pin
                copy.author = updated
                return copy
            }
            recomputeClusters()
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoModeEnabled else { return }
        isDemoModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.demoMode)
        HapticManager.shared.selection()
        if !enabled {
            viewerSelection = nil
        }
        Task {
            await self.dataService.setDemoMode(enabled)
            await self.refresh()
        }
    }

    // MARK: - Navigation

    func openViewer(for cluster: PinCluster, startingAt pinID: UUID?) {
        let ids = cluster.pins.map(\.id)
        let startIndex = pinID.flatMap { ids.firstIndex(of: $0) } ?? 0
        withAnimation(Theme.spring) {
            viewerSelection = ViewerSelection(id: cluster.id, pinIDs: ids, startIndex: startIndex)
        }
    }

    func closeViewer() {
        withAnimation(Theme.spring) {
            viewerSelection = nil
        }
    }

    func presentCamera() {
        closeViewer()
        isFriendsDrawerPresented = false
        isCameraPresented = true
    }

    func focusMap(on point: GeoPoint, spanMeters: Double = 1_500) {
        cameraTarget = CameraTarget(point: point, spanMeters: spanMeters)
    }

    /// Centers the map on a pin and optionally opens it, waiting for data if needed.
    func requestFocus(on pinID: UUID, openViewer: Bool) {
        pendingFocus = (pinID, openViewer)
        resolvePendingFocus(dropIfMissing: hasLoadedOnce && !isRefreshing)
    }

    /// Handles `pindrop://pin/{pinID}` (widget deep link).
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "pindrop" else { return }
        guard url.host()?.lowercased() == "pin" else { return }
        let identifier = url.pathComponents.first { $0 != "/" } ?? url.lastPathComponent
        guard let pinID = UUID(uuidString: identifier) else { return }
        isCameraPresented = false
        isFriendsDrawerPresented = false
        requestFocus(on: pinID, openViewer: true)
    }

    private func resolvePendingFocus(dropIfMissing: Bool) {
        guard let pending = pendingFocus else { return }
        guard let cluster = clusters.first(where: { $0.contains(pinID: pending.pinID) }) else {
            if dropIfMissing {
                pendingFocus = nil
                showToast(.info, title: String(localized: "toast.pinExpired.title"), subtitle: String(localized: "toast.pinExpired.subtitle"))
            }
            return
        }
        pendingFocus = nil
        focusMap(on: cluster.center, spanMeters: 900)
        if pending.openViewer {
            openViewer(for: cluster, startingAt: pending.pinID)
        }
    }

    // MARK: - Toasts

    func showToast(_ style: ToastMessage.Style, title: String, subtitle: String? = nil) {
        toastDismissTask?.cancel()
        toast = ToastMessage(style: style, title: title, subtitle: subtitle)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toast = nil
    }

    // MARK: - Internals

    private func replacePin(_ pin: PhotoPin) {
        guard let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        pins[index] = pin
        recomputeClusters()
    }

    private func recomputeClusters() {
        clusters = GeoClustering.cluster(activePins)
    }

    /// Reverse-geocodes hubs and pins without a place name, in the user's locale.
    private func resolveMissingPlaceNames() {
        for cluster in clusters {
            let key = cluster.id
            if placeNames[key] != nil || placeLookupsInFlight.contains(key) {
                continue
            }
            if !cluster.isHub, let existing = cluster.leadPin?.placeName {
                placeNames[key] = existing
                continue
            }
            placeLookupsInFlight.insert(key)
            let point = cluster.center
            Task { [weak self] in
                guard let self else { return }
                let name = await self.locationService.placeName(for: point)
                self.placeLookupsInFlight.remove(key)
                if let name {
                    self.placeNames[key] = name
                }
            }
        }
    }

    private func syncWidget() {
        WidgetSyncService.shared.sync(
            pins: pins,
            currentUserID: currentUser.id,
            isUnlocked: isUnlocked,
            userLocation: userLocation
        )
    }
}
