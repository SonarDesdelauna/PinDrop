import Observation
import SwiftUI
import WidgetKit

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

/// A recent position used to draw tire marks behind the user while moving.
struct TrailPoint: Hashable, Sendable {
    let point: GeoPoint
    let date: Date
}

/// A friend drawn on the map at their last shared position.
struct FriendOnMap: Identifiable, Hashable {
    let profile: UserProfile
    let location: FriendLocation

    var id: UUID { profile.id }
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
    var isPlacesPresented = false
    var isAddPlacePresented = false
    /// Saved places with visit counts (private to the user).
    private(set) var places: [SavedPlace] = []
    /// Where the user is right now and since when (device only).
    private(set) var presence: PresenceState?
    /// Other people's public places around the user.
    private(set) var publicPlaces: [PublicPlace] = []
    private(set) var notifications: [AppNotification] = []
    /// Time spent together, keyed by friend id.
    private(set) var friendTimes: [UUID: FriendTime] = [:]
    /// Recent positions while moving (tire marks).
    private(set) var trail: [TrailPoint] = []
    /// The app-wide accent color (the user's profile color). Changing it rebuilds the UI.
    private(set) var accentHex: String = AccentStore.hex
    var isNotificationsPresented = false
    /// Friends with the app open right now.
    private(set) var onlineFriendIDs: Set<UUID> = []
    private(set) var suggestions: [FriendSuggestion] = []
    /// Friends' last shared positions and location permissions.
    private(set) var friendLocations: [UUID: FriendLocation] = [:]
    private(set) var friendPermissions: [UUID: String] = [:]
    /// Red banners on the map, shown again every time the app is opened.
    var isAlwaysBannerDismissed = false
    var isFriendsLocationBannerDismissed = false
    var isLocationRemindersPresented = false
    /// Profile opened from the friends list, notifications or the map.
    var presentedProfile: UserProfile?

    let dataService: SupabaseDataService
    let locationService: LocationService

    @ObservationIgnored private var sessionUserID: UUID?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedOnlineFriends = false
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var placeLookupsInFlight: Set<String> = []
    @ObservationIgnored private var imageLoadsInFlight: Set<String> = []
    @ObservationIgnored private var failedImagePaths: Set<String> = []
    @ObservationIgnored private var pendingFocus: (pinID: UUID, openViewer: Bool)?
    @ObservationIgnored private var lastPresenceUpload: Date?
    @ObservationIgnored private var lastHeartbeat: Date?
    @ObservationIgnored private var publicPlacesAnchor: GeoPoint?
    @ObservationIgnored private var lastPresencePlaceIDs: Set<UUID> = []

    init(dataService: SupabaseDataService, locationService: LocationService) {
        self.dataService = dataService
        self.locationService = locationService
        // Background fixes ("Always" permission) are shared with friends even when the app
        // was relaunched by iOS and no screen is showing.
        locationService.backgroundFixHandler = { [dataService, locationService] point in
            // iOS gives the app ~10 s of runtime after a location wake-up: enough to upload.
            let permission = locationService.permissionName
            Task {
                try? await dataService.reportLocation(point, permission: permission)
            }
        }
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

    // MARK: - Social

    var unreadNotificationCount: Int {
        notifications.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
    }

    /// Friends whose position is shown on the map (shared in the last 24 hours).
    var visibleFriendLocations: [FriendOnMap] {
        let cutoff = Date.now.addingTimeInterval(-86_400)
        return friends.compactMap { friend in
            guard let location = friendLocations[friend.id], location.updatedAt > cutoff else { return nil }
            return FriendOnMap(profile: friend, location: location)
        }
    }

    /// Friends who don't share their location with "Always".
    var friendsWithoutAlways: [UserProfile] {
        friends.filter { friendPermissions[$0.id] != "always" }
    }

    func locationPermission(of friendID: UUID) -> String? {
        friendPermissions[friendID]
    }

    /// The app is opened again: show the location banners again.
    func resetLocationBanners() {
        isAlwaysBannerDismissed = false
        isFriendsLocationBannerDismissed = false
    }

    func requestAlwaysLocation() {
        locationService.requestAlwaysAuthorization()
    }

    func reloadFriendLocations() async {
        guard sessionPhase == .ready else { return }
        async let locationsLoad = try? dataService.fetchFriendLocations()
        async let permissionsLoad = try? dataService.fetchLocationPermissions()
        let (locations, permissions) = await (locationsLoad, permissionsLoad)
        if let locations {
            var map: [UUID: FriendLocation] = [:]
            for location in locations {
                map[location.userID] = location
            }
            if map != friendLocations {
                withAnimation(Theme.spring) {
                    friendLocations = map
                }
            }
        }
        if let permissions {
            var map: [UUID: String] = [:]
            for row in permissions {
                map[row.userID] = row.permission
            }
            friendPermissions = map
        }
    }

    func isOnline(_ userID: UUID) -> Bool {
        onlineFriendIDs.contains(userID)
    }

    /// The friend you spend the most time with.
    var bestFriend: (profile: UserProfile, time: FriendTime)? {
        friends
            .compactMap { friend in friendTimes[friend.id].map { (profile: friend, time: $0) } }
            .filter { $0.time.seconds > 0 || $0.time.isBestFriend }
            .max { lhs, rhs in
                if lhs.time.isBestFriend != rhs.time.isBestFriend { return !lhs.time.isBestFriend }
                return lhs.time.seconds < rhs.time.seconds
            }
    }

    /// Tells the server the app is open and checks which friends are online. A friend who just
    /// opened the app is announced with a popup.
    func refreshOnlinePresence() async {
        guard sessionPhase == .ready else { return }
        try? await dataService.touchPresence()
        guard let ids = try? await dataService.fetchOnlineFriends() else { return }
        let online = Set(ids)
        if hasLoadedOnlineFriends {
            let arrived = online.subtracting(onlineFriendIDs)
            if let friend = friends.first(where: { arrived.contains($0.id) }) {
                HapticManager.shared.success()
                showToast(.ping, title: Self.reconnectPhrase(for: friend.firstName))
            }
        }
        hasLoadedOnlineFriends = true
        if online != onlineFriendIDs {
            withAnimation(Theme.spring) {
                onlineFriendIDs = online
            }
        }
    }

    /// Called when the app goes to the background.
    func goOffline() {
        Task { [dataService] in
            try? await dataService.goOffline()
        }
    }

    private static func reconnectPhrase(for name: String) -> String {
        switch Int.random(in: 0..<5) {
        case 0: String(localized: "online.toast.1 \(name)")
        case 1: String(localized: "online.toast.2 \(name)")
        case 2: String(localized: "online.toast.3 \(name)")
        case 3: String(localized: "online.toast.4 \(name)")
        default: String(localized: "online.toast.5 \(name)")
        }
    }

    func reloadSuggestions() async {
        guard sessionPhase == .ready, let rows = try? await dataService.fetchSuggestions() else { return }
        let profiles = (try? await dataService.fetchProfiles(rows.map(\.profileID))) ?? []
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let result = rows.compactMap { row in
            byID[row.profileID].map { FriendSuggestion(profile: $0, mutualCount: row.mutualCount, isNearby: row.reason == "nearby") }
        }
        withAnimation(Theme.spring) {
            suggestions = result
        }
    }

    func friendTime(with friendID: UUID) -> FriendTime? {
        friendTimes[friendID]
    }

    func isBestFriend(_ friendID: UUID) -> Bool {
        friendTimes[friendID]?.isBestFriend ?? false
    }

    /// Public places worth drawing: hide the ones that are already in your own places.
    var visiblePublicPlaces: [PublicPlace] {
        let mine = places.map(\.location)
        return publicPlaces.filter { place in
            !mine.contains { GeoClustering.haversineDistance(from: $0, to: place.location) < 30 }
        }
    }

    private func applyAccent(_ hex: String) {
        guard hex.uppercased() != accentHex.uppercased() else { return }
        AccentStore.setHex(hex)
        accentHex = hex
        WidgetCenter.shared.reloadAllTimelines()
    }

    func openProfile(_ user: UserProfile) {
        presentedProfile = user
    }

    func loadProfileDetails(for user: UserProfile) async -> (profile: UserProfile, places: [PlaceSummary]) {
        let viewCount = (try? await dataService.recordProfileView(user.id)) ?? user.viewCount
        var profile = (try? await dataService.fetchProfile(user.id)) ?? user
        profile.viewCount = max(profile.viewCount, viewCount)
        let places = (try? await dataService.fetchPublicPlaces(of: user.id)) ?? []
        return (profile, places)
    }

    func reloadNotifications() async {
        guard sessionPhase == .ready, let fetched = try? await dataService.fetchNotifications() else { return }
        withAnimation(Theme.spring) {
            notifications = fetched
        }
    }

    func markNotificationsRead() async {
        guard unreadNotificationCount > 0 else { return }
        try? await dataService.markNotificationsRead()
        let now = Date.now
        notifications = notifications.map { item in
            guard item.isUnread else { return item }
            return AppNotification(
                id: item.id,
                kind: item.kind,
                createdAt: item.createdAt,
                readAt: now,
                payload: item.payload,
                actor: item.actor,
                place: item.place
            )
        }
    }

    func deleteNotification(_ notification: AppNotification) async {
        withAnimation(Theme.spring) {
            notifications.removeAll { $0.id == notification.id }
        }
        try? await dataService.deleteNotification(notification.id)
    }

    /// Accepts the friend request behind a notification.
    func acceptFriendRequest(from user: UserProfile) async {
        if let request = friendsSnapshot.incoming.first(where: { $0.requesterID == user.id }) {
            await respond(to: request, accept: true)
        } else if let result = await sendFriendRequest(to: user.username), result.isSuccess {
            showToast(.success, title: String(localized: "toast.friendAdded.title \(user.firstName)"))
        }
        await reloadNotifications()
    }

    /// Copies someone's public place into your own places.
    func addPlace(from summary: PlaceSummary) async -> Bool {
        await addPlace(name: summary.name, emoji: summary.emoji, at: summary.location, isPublic: false, addedFrom: summary.id)
    }

    func addPlace(from place: PublicPlace) async -> Bool {
        await addPlace(name: place.name, emoji: place.emoji, at: place.location, isPublic: false, addedFrom: place.id)
    }

    private func reloadFriendTimes() async {
        guard let rows = try? await dataService.fetchFriendTimes() else { return }
        var map: [UUID: FriendTime] = [:]
        for row in rows {
            map[row.other(than: currentUser.id)] = row
        }
        friendTimes = map
    }

    private func reloadPublicPlaces(force: Bool = false) async {
        guard let userLocation else { return }
        if !force, let anchor = publicPlacesAnchor, GeoClustering.haversineDistance(from: anchor, to: userLocation) < 1_000 {
            return
        }
        guard let fetched = try? await dataService.fetchPublicPlaces(near: userLocation) else { return }
        publicPlacesAnchor = userLocation
        withAnimation(Theme.spring) {
            publicPlaces = fetched
        }
    }

    /// Time-together heartbeat (at most once a minute) while the app is open.
    private func sendHeartbeatIfNeeded() async {
        guard let userLocation, locationService.isAuthorized else { return }
        if let lastHeartbeat, Date.now.timeIntervalSince(lastHeartbeat) < 55 { return }
        lastHeartbeat = .now
        _ = try? await dataService.heartbeat(at: userLocation)
        try? await dataService.reportLocation(userLocation, permission: locationService.permissionName)
    }

    private func updateTrail(with point: GeoPoint) {
        let now = Date.now
        let isMoving = (locationService.speed ?? 0) >= 1.5
        var updated = trail.filter { now.timeIntervalSince($0.date) < 90 && GeoClustering.haversineDistance(from: $0.point, to: point) < 350 }
        if isMoving {
            if let last = updated.last, GeoClustering.haversineDistance(from: last.point, to: point) < 4 {
                // Too close to the previous mark.
            } else {
                updated.append(TrailPoint(point: point, date: now))
            }
        }
        if updated.count > 60 {
            updated.removeFirst(updated.count - 60)
        }
        if updated != trail {
            trail = updated
        }
    }

    // MARK: - Presence & places

    /// The saved place the user is currently in, if any.
    var currentPlace: SavedPlace? {
        guard let userLocation else { return nil }
        return places
            .filter { $0.contains(userLocation) }
            .min {
                GeoClustering.haversineDistance(from: $0.location, to: userLocation)
                    < GeoClustering.haversineDistance(from: $1.location, to: userLocation)
            }
    }

    /// Since when the user has been at the current spot (or saved place).
    var presenceSince: Date? {
        if let arrived = currentPlace?.currentArrivedAt {
            if let since = presence?.since {
                return min(arrived, since)
            }
            return arrived
        }
        return presence?.since
    }

    private var presenceDefaultsKey: String? {
        sessionUserID.map { "pindrop.presence.\($0.uuidString)" }
    }

    private func loadPresence() {
        guard let key = presenceDefaultsKey,
              let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(PresenceState.self, from: data) else {
            presence = nil
            return
        }
        presence = Date.now.timeIntervalSince(stored.lastSeen) <= PresenceState.maximumGap ? stored : nil
    }

    private func savePresence() {
        guard let key = presenceDefaultsKey else { return }
        if let presence, let data = try? JSONEncoder().encode(presence) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Starts foreground location updates while the map is on screen.
    func startLiveTracking() {
        guard sessionPhase == .ready, locationService.isAuthorized else { return }
        locationService.liveFixHandler = { [weak self] point in
            self?.handleFix(point)
        }
        locationService.startLiveUpdates()
    }

    func stopLiveTracking() {
        locationService.stopLiveUpdates()
        locationService.liveFixHandler = nil
    }

    private func handleFix(_ point: GeoPoint) {
        userLocation = point
        updatePresence(with: point)
        updateTrail(with: point)
        uploadPresenceIfNeeded(point)
        Task { [weak self] in
            await self?.reloadPublicPlaces()
        }
    }

    private func updatePresence(with point: GeoPoint) {
        let now = Date.now
        if var current = presence,
           now.timeIntervalSince(current.lastSeen) <= PresenceState.maximumGap,
           GeoClustering.haversineDistance(from: current.anchor, to: point) <= PresenceState.leaveDistance {
            current.lastSeen = now
            presence = current
        } else {
            presence = PresenceState(anchor: point, since: now, lastSeen: now)
        }
        savePresence()
    }

    /// Records visits of saved places: immediately when entering one, then every few minutes.
    private func uploadPresenceIfNeeded(_ point: GeoPoint) {
        let inside = Set(places.filter { $0.contains(point) }.map(\.id))
        guard !inside.isEmpty else {
            lastPresencePlaceIDs = []
            return
        }
        let entered = !inside.isSubset(of: lastPresencePlaceIDs)
        let stale = lastPresenceUpload.map { Date.now.timeIntervalSince($0) > 240 } ?? true
        guard entered || stale else { return }
        lastPresencePlaceIDs = inside
        lastPresenceUpload = .now
        Task { [weak self] in
            guard let self else { return }
            if (try? await self.dataService.recordPresence(at: point)) != nil {
                await self.reloadPlaces()
                await self.reloadNotifications()
            }
        }
    }

    func reloadPlaces() async {
        guard sessionPhase == .ready, let fetched = try? await dataService.fetchPlaces() else { return }
        withAnimation(Theme.spring) {
            places = fetched
        }
    }

    func addPlace(name: String, emoji: String, at point: GeoPoint, isPublic: Bool, addedFrom: UUID? = nil) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await dataService.addPlace(name: trimmed, emoji: emoji, at: point, isPublic: isPublic, addedFrom: addedFrom)
            HapticManager.shared.success()
            lastPresencePlaceIDs = []
            if let userLocation, GeoClustering.haversineDistance(from: userLocation, to: point) <= Double(SavedPlace.defaultRadius) {
                _ = try? await dataService.recordPresence(at: userLocation)
            }
            await reloadPlaces()
            showToast(.success, title: String(localized: "places.added.title \(emoji) \(trimmed)"))
            return true
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
            return false
        }
    }

    func updatePlace(_ place: SavedPlace, name: String, emoji: String, isPublic: Bool) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await dataService.updatePlace(place.id, name: trimmed, emoji: emoji, isPublic: isPublic)
            HapticManager.shared.success()
            await reloadPlaces()
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    func deletePlace(_ place: SavedPlace) async {
        do {
            try await dataService.deletePlace(place.id)
            HapticManager.shared.selection()
            await reloadPlaces()
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    // MARK: - Images

    /// The image shown in map thumbnails: the pre-blurred preview while locked, the thumb otherwise.
    func thumbnail(for pin: PhotoPin) -> PinImage? {
        let path = isLocked(pin) ? pin.blurPath : pin.thumbPath
        if let data = images[path] {
            return PinImage(key: path, data: data)
        }
        if let data = images[pin.blurPath] {
            return PinImage(key: pin.blurPath, data: data)
        }
        return nil
    }

    /// The image shown in the viewer: full resolution when available.
    func fullImage(for pin: PhotoPin) -> PinImage? {
        if isLocked(pin) {
            return images[pin.blurPath].map { PinImage(key: pin.blurPath, data: $0) }
        }
        if let data = images[pin.imagePath] {
            return PinImage(key: pin.imagePath, data: data)
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
    /// Loads the session. The work runs in its own task, so views being rebuilt (for example
    /// when the accent color changes) can never cancel it halfway. Network hiccups at launch
    /// are retried silently before showing an error.
    func start(userID: UUID) async {
        if sessionUserID == userID, sessionPhase == .ready || startTask != nil { return }
        if let previous = sessionUserID, previous != userID {
            reset()
        }
        sessionUserID = userID
        sessionPhase = .loading
        HapticManager.shared.prepare()
        startTask = Task { [weak self] in
            await self?.performStart(userID: userID)
            self?.startTask = nil
        }
    }

    private func performStart(userID: UUID) async {
        var lastError: Error?
        for attempt in 0..<4 {
            guard sessionUserID == userID else { return }
            do {
                let profile = try await dataService.currentProfile()
                guard sessionUserID == userID else { return }
                currentUser = profile
                sessionPhase = .ready
                loadPresence()
                applyAccent(profile.avatarColorHex)
                lastError = nil
                break
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(600 * (attempt + 1)))
            }
        }
        if let lastError {
            sessionPhase = .failed(lastError.localizedDescription)
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
        stopLiveTracking()
        places = []
        presence = nil
        lastPresenceUpload = nil
        lastPresencePlaceIDs = []
        isPlacesPresented = false
        isAddPlacePresented = false
        isNotificationsPresented = false
        presentedProfile = nil
        publicPlaces = []
        notifications = []
        friendTimes = [:]
        trail = []
        lastHeartbeat = nil
        publicPlacesAnchor = nil
        applyAccent(AccentStore.defaultHex)
        housekeepingTask?.cancel()
        housekeepingTask = nil
        startTask?.cancel()
        startTask = nil
        onlineFriendIDs = []
        suggestions = []
        friendLocations = [:]
        friendPermissions = [:]
        isLocationRemindersPresented = false
        hasLoadedOnlineFriends = false
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
            updatePresence(with: fix)
        }
        await reloadPlaces()
        if let userLocation {
            uploadPresenceIfNeeded(userLocation)
        }
        async let notificationsLoad: Void = reloadNotifications()
        async let friendTimesLoad: Void = reloadFriendTimes()
        async let publicPlacesLoad: Void = reloadPublicPlaces(force: true)
        async let heartbeatLoad: Void = sendHeartbeatIfNeeded()
        async let presenceLoad: Void = refreshOnlinePresence()
        async let friendLocationsLoad: Void = reloadFriendLocations()
        _ = await (notificationsLoad, friendTimesLoad, publicPlacesLoad, heartbeatLoad, presenceLoad, friendLocationsLoad)
        if userLocation == nil {
            try? await dataService.reportLocation(nil, permission: locationService.permissionName)
        }
        do {
            async let profile = dataService.currentProfile()
            async let friends = dataService.fetchFriends()
            async let livePins = dataService.fetchActivePins()
            let (fetchedProfile, fetchedFriends, fetchedPins) = try await (profile, friends, livePins)
            let now = Date.now
            applyAccent(fetchedProfile.avatarColorHex)
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
                await self.sendHeartbeatIfNeeded()
                await self.refreshOnlinePresence()
                await self.reloadFriendLocations()
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
        applyAccent(saved.avatarColorHex)
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

    /// Closes every sheet and centers the map on a point.
    func showOnMap(_ point: GeoPoint) {
        presentedProfile = nil
        isNotificationsPresented = false
        isFriendsDrawerPresented = false
        isPlacesPresented = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.focusMap(on: point, spanMeters: 700)
        }
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
