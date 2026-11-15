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

/// Global observable state for the signed-in session: profile, friends, pins, clusters,
/// downloaded images, unlock state, selection and routing.
@MainActor
@Observable
final class AppState {
    enum SessionPhase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var sessionPhase: SessionPhase = .idle
    private(set) var currentUser: UserProfile = .placeholder
    private(set) var friendsSnapshot: FriendsSnapshot = .empty
    private(set) var pins: [PhotoPin] = []
    private(set) var clusters: [PinCluster] = []
    private(set) var placeNames: [String: String] = [:]
    /// Downloaded images keyed by storage path.
    private(set) var images: [String: Data] = [:]
    private(set) var userLocation: GeoPoint?
    private(set) var isRefreshing = false
    private(set) var hasLoadedOnce = false
    private(set) var cameraTarget: CameraTarget?
    private(set) var toast: ToastMessage?
    var viewerSelection: ViewerSelection?
    var isCameraPresented = false
    var isFriendsDrawerPresented = false
    var isProfileEditorPresented = false

    let dataService: SupabaseDataService
    let locationService: LocationService

    @ObservationIgnored private var sessionUserID: UUID?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var placeLookupsInFlight: Set<String> = []
    @ObservationIgnored private var imageLoadsInFlight: Set<String> = []
    @ObservationIgnored private var failedImagePaths: Set<String> = []
    @ObservationIgnored private var pendingFocus: (pinID: UUID, openViewer: Bool)?

    init(dataService: SupabaseDataService, locationService: LocationService) {
        self.dataService = dataService
        self.locationService = locationService
    }

    // MARK: - Derived state

    var friends: [UserProfile] {
        friendsSnapshot.friends
    }

    var needsProfileSetup: Bool {
        sessionPhase == .ready && !currentUser.isSetup
    }

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

    var pendingRequestCount: Int {
        friendsSnapshot.incoming.count
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

    // MARK: - Images

    /// The image shown in map thumbnails: the pre-blurred preview while locked, the thumb otherwise.
    func thumbnail(for pin: PhotoPin) -> (key: String, data: Data)? {
        let path = isLocked(pin) ? pin.blurPath : pin.thumbPath
        if let data = images[path] {
            return (path, data)
        }
        if let data = images[pin.blurPath] {
            return (pin.blurPath, data)
        }
        return nil
    }

    /// The image shown in the viewer: full resolution when available.
    func fullImage(for pin: PhotoPin) -> (key: String, data: Data)? {
        if isLocked(pin) {
            return images[pin.blurPath].map { (pin.blurPath, $0) }
        }
        if let data = images[pin.imagePath] {
            return (pin.imagePath, data)
        }
        return thumbnail(for: pin)
    }

    func loadFullImage(for pin: PhotoPin) async {
        guard !isLocked(pin) else { return }
        await loadImage(path: pin.imagePath)
    }

    private func loadImage(path: String) async {
        guard images[path] == nil, !imageLoadsInFlight.contains(path), !failedImagePaths.contains(path) else { return }
        imageLoadsInFlight.insert(path)
        defer { imageLoadsInFlight.remove(path) }
        do {
            let data = try await dataService.loadImage(path: path)
            images[path] = data
        } catch {
            failedImagePaths.insert(path)
        }
    }

    /// Downloads the thumbnails the map needs (blur previews while locked).
    private func prefetchThumbnails() {
        for pin in activePins {
            let paths = isLocked(pin) ? [pin.blurPath] : [pin.thumbPath, pin.blurPath]
            for path in paths where images[path] == nil {
                Task { [weak self] in
                    await self?.loadImage(path: path)
                    self?.syncWidget()
                }
            }
        }
    }

    // MARK: - Session lifecycle

    /// Loads the signed-in user's profile and content. Called when Auth reports a session.
    func start(userID: UUID) async {
        if sessionUserID == userID, sessionPhase == .ready { return }
        if sessionUserID != userID {
            reset()
        }
        sessionUserID = userID
        sessionPhase = .loading
        HapticManager.shared.prepare()
        do {
            currentUser = try await dataService.currentProfile()
            sessionPhase = .ready
        } catch {
            sessionPhase = .failed(error.localizedDescription)
            return
        }
        await refresh()
        startHousekeeping()
    }

    func retryStart() async {
        guard let sessionUserID else { return }
        sessionPhase = .idle
        await start(userID: sessionUserID)
    }

    /// Clears every piece of user data (sign-out or account switch).
    func reset() {
        housekeepingTask?.cancel()
        housekeepingTask = nil
        sessionUserID = nil
        sessionPhase = .idle
        currentUser = .placeholder
        friendsSnapshot = .empty
        pins = []
        clusters = []
        placeNames = [:]
        images = [:]
        failedImagePaths = []
        viewerSelection = nil
        isCameraPresented = false
        isFriendsDrawerPresented = false
        isProfileEditorPresented = false
        hasLoadedOnce = false
        pendingFocus = nil
        ImageCache.removeAll()
        WidgetSyncService.shared.clear()
    }

    /// Reloads profile, friends, pins and pings. Concurrent calls are coalesced into one extra pass.
    func refresh() async {
        guard sessionPhase == .ready else { return }
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
        do {
            async let profile = dataService.currentProfile()
            async let friends = dataService.fetchFriends()
            async let livePins = dataService.fetchActivePins()
            let (fetchedProfile, fetchedFriends, fetchedPins) = try await (profile, friends, livePins)
            let now = Date.now
            withAnimation(Theme.spring) {
                currentUser = fetchedProfile
                friendsSnapshot = fetchedFriends
                pins = fetchedPins
                    .filter { !$0.isExpired(at: now) }
                    .sorted { $0.createdAt > $1.createdAt }
                recomputeClusters()
            }
            hasLoadedOnce = true
            closeViewerIfNeeded()
            resolveMissingPlaceNames()
            prefetchThumbnails()
            syncWidget()
            resolvePendingFocus(dropIfMissing: true)
        } catch is CancellationError {
            return
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
        await deliverPings()
    }

    /// Shows unseen "On my way" pings as a toast and marks them as seen.
    private func deliverPings() async {
        guard let pings = try? await dataService.fetchUnseenPings(), let latest = pings.first else { return }
        let duration = LocaleFormatter.walkingDuration(seconds: TimeInterval(latest.etaSeconds))
        HapticManager.shared.success()
        showToast(
            .ping,
            title: String(localized: "toast.incomingPing.title \(latest.sender.firstName)"),
            subtitle: String(localized: "toast.incomingPing.subtitle \(duration)")
        )
        try? await dataService.markPingsSeen(pings.map(\.id))
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
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.pruneExpiredPins()
                tick += 1
                if tick.isMultiple(of: 2) {
                    await self.refresh()
                }
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

    // MARK: - Pins

    /// Publishes a live drop. If the map was locked, it unlocks instantly with an animation.
    func publish(processed: ProcessedImage, location: GeoPoint, placeName: String?, caption: String) async throws {
        let wasLocked = !isUnlocked
        let draft = PinDraft(image: processed, location: location, placeName: placeName, caption: caption)
        let pin = try await dataService.publishPin(draft)
        images[pin.imagePath] = processed.fullData
        images[pin.thumbPath] = processed.thumbnailData
        images[pin.blurPath] = processed.blurData
        userLocation = location
        withAnimation(Theme.spring) {
            pins.removeAll { $0.id == pin.id }
            pins.insert(pin, at: 0)
            recomputeClusters()
        }
        failedImagePaths.removeAll()
        resolveMissingPlaceNames()
        prefetchThumbnails()
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
        guard let pin = pins.first(where: { $0.id == pinID }) else { return }
        HapticManager.shared.reaction()
        do {
            let updated = try await dataService.toggleReaction(emoji, on: pin)
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

    // MARK: - Profile

    /// Saves the profile; uploads `newAvatar` first when provided, or clears the photo when
    /// `removeAvatar` is set.
    func saveProfile(_ draft: UserProfile, newAvatar: Data?, removeAvatar: Bool) async throws {
        var profile = draft
        let previousPath = currentUser.avatarPath
        if let newAvatar {
            profile.avatarPath = try await dataService.uploadAvatar(newAvatar)
        } else if removeAvatar {
            profile.avatarPath = nil
        }
        profile.isSetup = true
        let saved = try await dataService.updateProfile(ProfileUpdate(profile: profile))
        if let previousPath, previousPath != saved.avatarPath {
            Task { await dataService.deleteAvatar(path: previousPath) }
        }
        withAnimation(Theme.spring) {
            currentUser = saved
            pins = pins.map { pin in
                guard pin.author.id == saved.id else { return pin }
                var copy = pin
                copy.author = saved
                return copy
            }
            recomputeClusters()
        }
        HapticManager.shared.success()
        if hasLoadedOnce == false {
            await refresh()
        }
    }

    func isUsernameAvailable(_ username: String) async -> Bool? {
        try? await dataService.isUsernameAvailable(username)
    }

    // MARK: - Friends

    func sendFriendRequest(to target: String) async -> FriendRequestResult? {
        let cleaned = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        do {
            let result = try await dataService.sendFriendRequest(to: cleaned)
            if result.isSuccess {
                HapticManager.shared.success()
                await refresh()
            } else {
                HapticManager.shared.warning()
            }
            return result
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
            return nil
        }
    }

    func respond(to request: Friendship, accept: Bool) async {
        do {
            try await dataService.respondToFriendRequest(request.id, accept: accept)
            if accept {
                HapticManager.shared.success()
                showToast(.success, title: String(localized: "toast.friendAdded.title \(request.requester.firstName)"))
            } else {
                HapticManager.shared.selection()
            }
            await refresh()
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    func cancelRequest(_ request: Friendship) async {
        await removeFriendship(id: request.id)
    }

    func removeFriend(_ friend: UserProfile) async {
        guard let id = friendsSnapshot.friendshipIDs[friend.id] else { return }
        await removeFriendship(id: id)
    }

    private func removeFriendship(id: UUID) async {
        do {
            try await dataService.removeFriendship(id)
            HapticManager.shared.selection()
            await refresh()
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
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
        guard sessionPhase == .ready else { return }
        var thumbnails: [UUID: Data] = [:]
        for pin in friendActivePins {
            if let image = thumbnail(for: pin) {
                thumbnails[pin.id] = image.data
            }
        }
        WidgetSyncService.shared.sync(
            pins: pins,
            thumbnails: thumbnails,
            currentUserID: currentUser.id,
            isUnlocked: isUnlocked,
            userLocation: userLocation
        )
    }
}
