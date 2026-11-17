import MapKit
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

/// Friends standing together, drawn as one bubble of small side-by-side avatars.
struct FriendGroupOnMap: Identifiable, Hashable {
    let members: [FriendOnMap]

    var id: String {
        members.map(\.profile.id.uuidString).sorted().joined(separator: "|")
    }

    var profiles: [UserProfile] {
        members.map(\.profile)
    }

    /// Where the bubble is drawn: the most recently updated member.
    var location: GeoPoint {
        (members.max { $0.location.updatedAt < $1.location.updatedAt } ?? members[0]).location.location
    }

    var updatedAt: Date {
        members.map(\.location.updatedAt).max() ?? .now
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
    private(set) var userLocation: GeoPoint? {
        didSet {
            if userLocation != oldValue {
                glideDisplayLocation(to: userLocation)
            }
        }
    }
    /// Where your dot is drawn: glides smoothly between location fixes instead of jumping.
    private(set) var displayLocation: GeoPoint?
    @ObservationIgnored private var glideTask: Task<Void, Never>?
    @ObservationIgnored private var lastLocationChange: Date?
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
    /// Public places you are the Mayor of (crown on your own places).
    private(set) var myMayorships: [Mayorship] = []
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
    /// What you and your friends are listening to, keyed by user id.
    private(set) var nowPlayingByUser: [UUID: NowPlaying] = [:]
    /// Your linked music sources.
    private(set) var musicStatus: MusicStatus?
    /// Red banners on the map, shown again every time the app is opened.
    var isAlwaysBannerDismissed = false
    var isFriendsLocationBannerDismissed = false
    var isLocationRemindersPresented = false
    /// Profile opened from the friends list, notifications or the map.
    var presentedProfile: UserProfile?

    // MARK: Sync Shot, Sfiorati, Neon Trails, Geo-Capsules

    /// "Sfiorati" of the last 6 hours, newest first.
    private(set) var crossPaths: [CrossPathEvent] = []
    private(set) var dismissedCrossPathIDs: Set<UUID> = []
    /// Live Geo-Capsules you can see (yours and your friends').
    private(set) var capsules: [GeoCapsule] = []
    private(set) var openedCapsuleIDs: Set<UUID> = []
    /// How many friends opened each of your capsules.
    private(set) var capsuleOpenCounts: [UUID: Int] = [:]
    private(set) var capsuleSecrets: [UUID: String] = [:]
    var presentedCapsule: GeoCapsule?
    /// The capsule that just opened, shown with a full-screen celebration.
    var celebratingCapsule: GeoCapsule?
    var isRecapPresented = false
    /// The Sync Shot studio being shown.
    var syncShotContext: SyncShotContext?
    private(set) var incomingSyncInvite: IncomingSyncInvite?
    /// Demo mode: fake friends, pins, a capsule and a cross-path around your real position.
    private(set) var isDemoModeEnabled = UserDefaults.standard.bool(forKey: AppState.demoDefaultsKey)
    private(set) var demo: DemoScenario?
    private(set) var demoPinIDs: Set<UUID> = []
    /// Fake position used by the demo "walk to the capsule" control.
    private(set) var simulatedLocation: GeoPoint?
    @ObservationIgnored private var capsuleOpenAttempts: [UUID: Date] = [:]
    @ObservationIgnored private var demoOpenedCapsuleIDs: Set<UUID> = []
    @ObservationIgnored private var syncInviteTask: Task<Void, Never>?
    @ObservationIgnored private var lastCrossPathDetection: Date?
    @ObservationIgnored private var hasLoadedCrossPaths = false
    @ObservationIgnored private var dismissedSyncInviteIDs: Set<UUID> = []
    /// Your evening trail following the streets (walking/driving directions between pins).
    private(set) var myRoutePoints: [GeoPoint] = []
    @ObservationIgnored private var routeCache: [String: [GeoPoint]] = [:]
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private var routedPinIDs: [UUID] = []
    nonisolated static let demoDefaultsKey = "pindrop.demo.enabled"

    let dataService: SupabaseDataService
    let locationService: LocationService
    /// Chats and stories.
    let social: SocialStore
    /// System notifications for what friends do (messages, pins, capsules, stories...).
    @ObservationIgnored let push: PushNotifier

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
        self.social = SocialStore(dataService: dataService)
        let push = PushNotifier(dataService: dataService)
        self.push = push
        // Background fixes ("Always" permission) are shared with friends even when the app
        // was relaunched by iOS and no screen is showing.
        locationService.backgroundFixHandler = { [dataService, locationService, push] point in
            // iOS gives the app ~10 s of runtime after a location wake-up: enough to upload
            // and to look for new notifications.
            let permission = locationService.permissionName
            Task {
                try? await dataService.reportLocation(point, permission: permission)
            }
            Task {
                await push.check()
            }
        }
        push.onOpen = { [weak self] route in
            self?.openPushRoute(route)
        }
        push.shouldPresentInForeground = { [weak self] event in
            // No banner for chat messages while the chats are on screen.
            !(event.kind == "message" && self?.social.isChatListPresented == true)
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
            .filter { $0.author.id == currentUser.id && !$0.isExpired(at: now) && !demoPinIDs.contains($0.id) }
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
        isUnlocked ? 0 : friendActivePins.filter { isLocked($0) }.count
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

    /// Friends' photos stay blurred until you drop your own, unless you crossed paths there.
    func isLocked(_ pin: PhotoPin) -> Bool {
        !isUnlocked && !isOwn(pin) && !crossPathUnlockedPinIDs.contains(pin.id)
    }

    /// Pins unlocked for both people by a cross-path.
    var crossPathUnlockedPinIDs: Set<UUID> {
        Set(crossPaths.flatMap { [$0.myPinID, $0.friendPinID] })
    }

    func isDemoPin(_ pin: PhotoPin) -> Bool {
        demoPinIDs.contains(pin.id)
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
        var result = friends.compactMap { friend -> FriendOnMap? in
            guard let location = friendLocations[friend.id], location.updatedAt > cutoff else { return nil }
            return FriendOnMap(profile: friend, location: location)
        }
        if let demo {
            for friend in demo.friends {
                if let location = demo.friendLocations[friend.id] {
                    result.append(FriendOnMap(profile: friend, location: location))
                }
            }
        }
        return result
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

    /// Someone's current song, or the last one heard in the past day.
    func nowPlaying(for userID: UUID) -> NowPlaying? {
        nowPlayingByUser[userID]
    }

    /// Someone's song only while it is playing right now.
    func liveMusic(for userID: UUID) -> NowPlaying? {
        guard let entry = nowPlayingByUser[userID], entry.isLive() else { return nil }
        return entry
    }

    func reloadMusic() async {
        guard sessionPhase == .ready else { return }
        await AppleMusicReporter.reportIfNeeded(using: dataService)
        async let rowsLoad = try? dataService.fetchNowPlaying()
        async let statusLoad = try? dataService.musicStatus()
        let (rows, status) = await (rowsLoad, statusLoad)
        if let rows {
            var map: [UUID: NowPlaying] = [:]
            for row in rows {
                map[row.userID] = row
            }
            if map != nowPlayingByUser {
                withAnimation(Theme.spring) {
                    nowPlayingByUser = map
                }
            }
        }
        if let status, status != musicStatus {
            musicStatus = status
        }
    }

    func reloadFriendLocations() async {
        guard sessionPhase == .ready else { return }
        Task { [weak self] in await self?.reloadMusic() }
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
        onlineFriendIDs.contains(userID) || (demo?.onlineIDs.contains(userID) ?? false)
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

    /// Moves the drawn dot continuously to the new fix, over about the time between fixes.
    private func glideDisplayLocation(to target: GeoPoint?) {
        glideTask?.cancel()
        let now = Date.now
        let elapsed = lastLocationChange.map { now.timeIntervalSince($0) } ?? 1
        lastLocationChange = now
        guard let target, let start = displayLocation,
              GeoClustering.haversineDistance(from: start, to: target) < 500 else {
            displayLocation = target
            return
        }
        let duration = min(max(elapsed, 0.35), 2.2)
        glideTask = Task { [weak self] in
            let begin = Date.now
            while !Task.isCancelled {
                let progress = min(1, Date.now.timeIntervalSince(begin) / duration)
                self?.displayLocation = GeoPoint(
                    latitude: start.latitude + (target.latitude - start.latitude) * progress,
                    longitude: start.longitude + (target.longitude - start.longitude) * progress
                )
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func updateTrail(with point: GeoPoint) {
        let now = Date.now
        let isMoving = (locationService.speed ?? 0) >= 1.5
        var updated = trail.filter { now.timeIntervalSince($0.date) < 90 && GeoClustering.haversineDistance(from: $0.point, to: point) < 350 }
        if isMoving {
            if let last = updated.last, GeoClustering.haversineDistance(from: last.point, to: point) < 1.5 {
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

    private func handleFix(_ fix: GeoPoint) {
        let point = simulatedLocation ?? fix
        userLocation = point
        checkCapsuleProximity(at: point)
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

    func reloadMayorships() async {
        guard sessionPhase == .ready, let fetched = try? await dataService.fetchMayorships(of: currentUser.id) else { return }
        if fetched != myMayorships {
            withAnimation(Theme.spring) {
                myMayorships = fetched
            }
        }
    }

    /// Whether you are the Mayor of one of your own public places.
    func isMayor(of place: SavedPlace) -> Bool {
        myMayorships.contains { $0.placeID == place.id }
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
        push.start()
        if let route = pendingPushRoute {
            pendingPushRoute = nil
            openPushRoute(route)
        }
    }

    // MARK: - Device notifications

    @ObservationIgnored private var pendingPushRoute: PushRoute?

    /// Opens what a tapped notification is about (waits for the session when needed).
    func openPushRoute(_ route: PushRoute) {
        guard sessionPhase == .ready else {
            pendingPushRoute = route
            return
        }
        switch route {
        case .chat(let threadID):
            Task {
                if let userID = sessionUserID {
                    await social.refresh(userID: userID)
                }
                social.isChatListPresented = true
                social.openThreadID = threadID
            }
        case .story(let authorID):
            Task {
                if let userID = sessionUserID {
                    await social.refresh(userID: userID)
                }
                social.storyViewerStart = authorID
            }
        case .pin(let pinID):
            Task {
                await refresh()
                openPin(pinID)
            }
        case .notifications:
            isNotificationsPresented = true
        }
    }

    func retryStart() async {
        guard let sessionUserID else { return }
        sessionPhase = .idle
        await start(userID: sessionUserID)
    }

    /// Clears every piece of user data (sign-out or account switch).
    func reset() {
        stopLiveTracking()
        push.stop()
        pendingPushRoute = nil
        places = []
        presence = nil
        lastPresenceUpload = nil
        lastPresencePlaceIDs = []
        isPlacesPresented = false
        isAddPlacePresented = false
        isNotificationsPresented = false
        presentedProfile = nil
        publicPlaces = []
        myMayorships = []
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
        syncInviteTask?.cancel()
        syncInviteTask = nil
        crossPaths = []
        dismissedCrossPathIDs = []
        capsules = []
        openedCapsuleIDs = []
        capsuleOpenCounts = [:]
        capsuleSecrets = [:]
        presentedCapsule = nil
        celebratingCapsule = nil
        isRecapPresented = false
        syncShotContext = nil
        incomingSyncInvite = nil
        demo = nil
        demoPinIDs = []
        simulatedLocation = nil
        capsuleOpenAttempts = [:]
        demoOpenedCapsuleIDs = []
        lastCrossPathDetection = nil
        hasLoadedCrossPaths = false
        dismissedSyncInviteIDs = []
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
        social.reset()
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
            userLocation = simulatedLocation ?? fix
            updatePresence(with: fix)
        }
        if isDemoModeEnabled, demo == nil {
            buildDemo()
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
        async let mayorshipsLoad: Void = reloadMayorships()
        _ = await (notificationsLoad, friendTimesLoad, publicPlacesLoad, heartbeatLoad, presenceLoad, friendLocationsLoad, mayorshipsLoad)
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
                pins = composedPins(server: fetchedPins.filter { !$0.isExpired(at: now) })
                recomputeClusters()
            }
            hasLoadedOnce = true
            closeViewerIfNeeded()
            resolveMissingPlaceNames()
            prefetchThumbnails()
            syncWidget()
            resolvePendingFocus(dropIfMissing: true)
            if isDemoModeEnabled, !social.hasDemo {
                social.installDemo(currentUser: fetchedProfile)
            }
            await social.refresh(userID: fetchedProfile.id)
        } catch is CancellationError {
            return
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
        async let capsulesLoad: Void = reloadCapsules()
        async let crossPathsLoad: Void = reloadCrossPaths()
        async let invitesLoad: Void = pollSyncInvites()
        _ = await (capsulesLoad, crossPathsLoad, invitesLoad)
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
            userLocation = simulatedLocation ?? fix
            syncWidget()
        }
    }

    private func startHousekeeping() {
        startSyncInvitePolling()
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
                } else if self.currentUser.isSetup {
                    await self.social.refresh(userID: self.currentUser.id)
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
    @discardableResult
    func publish(processed: ProcessedImage, location: GeoPoint, placeName: String?, caption: String, syncSessionID: UUID? = nil, video: URL? = nil) async throws -> PhotoPin {
        let wasLocked = !isUnlocked
        let draft = PinDraft(image: processed, location: location, placeName: placeName, caption: caption, syncSessionID: syncSessionID, video: video)
        let pin = try await dataService.publishPin(draft)
        if let video, let path = pin.videoPath {
            dataService.cacheVideo(video, key: "pins/\(path)")
        }
        images[pin.imagePath] = processed.fullData
        images[pin.thumbPath] = processed.thumbnailData
        images[pin.blurPath] = processed.blurData
        userLocation = location
        withAnimation(Theme.spring) {
            pins.removeAll { $0.id == pin.id }
            pins.insert(pin, at: 0)
            pins = attachSyncPartners(pins)
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
        return pin
    }

    func toggleReaction(_ emoji: String, on pinID: UUID) async {
        guard let pin = pins.first(where: { $0.id == pinID }) else { return }
        HapticManager.shared.reaction()
        if isDemoPin(pin) {
            var copy = pin
            if copy.hasReaction(emoji, from: currentUser.id) {
                copy.reactions.removeAll { $0.emoji == emoji && $0.userID == currentUser.id }
            } else {
                copy.reactions.append(Reaction(userID: currentUser.id, emoji: emoji, createdAt: .now))
            }
            replacePin(copy)
            return
        }
        do {
            let updated = try await dataService.toggleReaction(emoji, on: pin)
            replacePin(updated)
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    func sendOnMyWay(to pin: PhotoPin, etaSeconds: TimeInterval) async throws {
        if !isDemoPin(pin) {
            try await dataService.sendOnMyWayPing(to: pin, etaSeconds: etaSeconds)
        }
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
    func saveProfile(_ draft: UserProfile, newAvatar: Data?, removeAvatar: Bool, newLive: LiveAvatarDraft? = nil) async throws {
        var profile = draft
        let previousPath = currentUser.avatarPath
        let previousLive = [currentUser.avatarLivePhotoPath, currentUser.avatarLiveVideoPath].compactMap { $0 }
        if let newAvatar {
            profile.avatarPath = try await dataService.uploadAvatar(newAvatar)
            profile.avatarLivePhotoPath = nil
            profile.avatarLiveVideoPath = nil
            if let newLive, let paths = try? await dataService.uploadLiveAvatar(newLive) {
                profile.avatarLivePhotoPath = paths.photo
                profile.avatarLiveVideoPath = paths.video
            }
        } else if removeAvatar {
            profile.avatarPath = nil
            profile.avatarLivePhotoPath = nil
            profile.avatarLiveVideoPath = nil
        }
        profile.isSetup = true
        let saved = try await dataService.updateProfile(ProfileUpdate(profile: profile))
        applyAccent(saved.avatarColorHex)
        if let previousPath, previousPath != saved.avatarPath {
            Task { await dataService.deleteAvatar(path: previousPath) }
        }
        for path in previousLive where path != saved.avatarLivePhotoPath && path != saved.avatarLiveVideoPath {
            Task { await dataService.deleteAvatar(path: path) }
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
        clusters = GeoClustering.cluster(mapPins)
        updateMyRoute()
    }

    /// Live pins drawn on the map: each Sync Shot appears once (your half when you took part).
    var mapPins: [PhotoPin] {
        var seenSessions: Set<UUID> = []
        let ordered = activePins.sorted { lhs, rhs in
            let lhsOwn = isOwn(lhs)
            let rhsOwn = isOwn(rhs)
            if lhsOwn != rhsOwn { return lhsOwn }
            return lhs.createdAt > rhs.createdAt
        }
        return ordered
            .filter { pin in
                guard let session = pin.syncSessionID else { return true }
                return seenSessions.insert(session).inserted
            }
            .sorted { $0.createdAt > $1.createdAt }
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
        for pin in friendActivePins where !isDemoPin(pin) {
            if let image = thumbnail(for: pin) {
                thumbnails[pin.id] = image.data
            }
        }
        WidgetSyncService.shared.sync(
            pins: pins.filter { !isDemoPin($0) },
            thumbnails: thumbnails,
            currentUserID: currentUser.id,
            isUnlocked: isUnlocked,
            userLocation: userLocation
        )
    }
}

// MARK: - Sync Shot, Sfiorati, Neon Trails, Geo-Capsules, demo mode

extension AppState {
    // MARK: Pins composition

    /// Server pins plus demo pins (newest first), with Sync Shot partners attached.
    fileprivate func composedPins(server: [PhotoPin]) -> [PhotoPin] {
        let now = Date.now
        let demoPins = (demo?.pins ?? []).filter { !$0.isExpired(at: now) }
        let serverOnly = server.filter { !demoPinIDs.contains($0.id) }
        return attachSyncPartners((serverOnly + demoPins).sorted { $0.createdAt > $1.createdAt })
    }

    /// Fills `syncPartnerProfile` on both halves of every Sync Shot.
    fileprivate func attachSyncPartners(_ list: [PhotoPin]) -> [PhotoPin] {
        let bySession = Dictionary(grouping: list.filter { $0.syncSessionID != nil }) { $0.syncSessionID ?? UUID() }
        guard !bySession.isEmpty else { return list }
        return list.map { pin in
            guard let session = pin.syncSessionID,
                  let partner = bySession[session]?.first(where: { $0.id != pin.id }) else { return pin }
            var copy = pin
            copy.syncPartnerProfile = partner.author
            if copy.syncPartnerImageData == nil, isDemoPin(partner) {
                copy.syncPartnerImageData = images[partner.imagePath]
            }
            return copy
        }
    }

    /// Adds or replaces pins fetched outside the regular refresh (e.g. a Sync Shot partner).
    func ingest(_ fetched: [PhotoPin]) {
        guard !fetched.isEmpty else { return }
        var updated = pins
        for pin in fetched where !pin.isExpired() {
            updated.removeAll { $0.id == pin.id }
            updated.append(pin)
        }
        withAnimation(Theme.spring) {
            pins = attachSyncPartners(updated.sorted { $0.createdAt > $1.createdAt })
            recomputeClusters()
        }
        prefetchThumbnails()
    }

    /// The other half of a Sync Shot, if it is loaded.
    func syncPartner(of pin: PhotoPin) -> PhotoPin? {
        guard let session = pin.syncSessionID else { return nil }
        return pins.first { $0.syncSessionID == session && $0.id != pin.id }
    }

    // MARK: Neon Trails & Recap

    /// Everyone's evening joined chronologically (people with at least two live pins).
    var neonTrails: [NeonTrail] {
        NeonTrail.trails(from: activePins, currentUserID: currentUser.id)
    }

    /// Statistics of your evening for the Recap.
    var recapSummary: TrailSummary {
        TrailSummary.make(pins: activePins, currentUserID: currentUser.id, crossPaths: crossPaths, routePoints: myRoutePoints)
    }

    // MARK: Sfiorati

    /// The newest cross-path still to show in the map banner.
    var activeCrossPath: CrossPathEvent? {
        let liveIDs = Set(activePins.map(\.id))
        return crossPaths.first { event in
            !dismissedCrossPathIDs.contains(event.id) && liveIDs.contains(event.myPinID) && liveIDs.contains(event.friendPinID)
        }
    }

    private var dismissedCrossPathsKey: String? {
        sessionUserID.map { "pindrop.crossPaths.dismissed.\($0.uuidString)" }
    }

    func dismissCrossPath(_ event: CrossPathEvent) {
        withAnimation(Theme.spring) {
            _ = dismissedCrossPathIDs.insert(event.id)
        }
        if let key = dismissedCrossPathsKey {
            UserDefaults.standard.set(dismissedCrossPathIDs.map(\.uuidString), forKey: key)
        }
    }

    /// Opens both photos of a cross-path side by side in the viewer.
    func openCrossPath(_ event: CrossPathEvent) {
        HapticManager.shared.pinTap()
        focusMap(on: event.location, spanMeters: 500)
        withAnimation(Theme.spring) {
            viewerSelection = ViewerSelection(id: "cross-\(event.id.uuidString)", pinIDs: [event.friendPinID, event.myPinID], startIndex: 0)
        }
    }

    func reloadCrossPaths() async {
        guard sessionPhase == .ready else { return }
        if dismissedCrossPathIDs.isEmpty, let key = dismissedCrossPathsKey,
           let stored = UserDefaults.standard.stringArray(forKey: key) {
            dismissedCrossPathIDs = Set(stored.compactMap(UUID.init(uuidString:)))
        }
        if lastCrossPathDetection.map({ Date.now.timeIntervalSince($0) > 300 }) ?? true {
            lastCrossPathDetection = .now
            try? await dataService.detectCrossPaths()
        }
        let rows = (try? await dataService.fetchCrossPaths()) ?? []
        var profiles: [UUID: UserProfile] = [:]
        for friend in friends {
            profiles[friend.id] = friend
        }
        for pin in pins {
            profiles[pin.author.id] = pin.author
        }
        let serverEvents = CrossPathsDetector.events(from: rows, currentUserID: currentUser.id, profiles: profiles)
        applyCrossPaths(serverEvents + (demo?.crossPaths ?? []))
    }

    fileprivate func applyCrossPaths(_ events: [CrossPathEvent]) {
        var unique: [UUID: CrossPathEvent] = [:]
        for event in events {
            unique[event.id] = event
        }
        let sorted = unique.values.sorted { $0.detectedAt > $1.detectedAt }
        let previousIDs = Set(crossPaths.map(\.id))
        let arrived = sorted.filter { !previousIDs.contains($0.id) && !dismissedCrossPathIDs.contains($0.id) }
        if sorted.map(\.id) != crossPaths.map(\.id) {
            withAnimation(Theme.spring) {
                crossPaths = sorted
            }
            prefetchThumbnails()
        }
        if hasLoadedCrossPaths, let first = arrived.first {
            HapticManager.shared.crossPath()
            showToast(
                .ping,
                title: String(localized: "crossPath.toast.title \(first.friend.firstName)"),
                subtitle: String(localized: "crossPath.toast.subtitle")
            )
        }
        hasLoadedCrossPaths = true
    }

    // MARK: Sync Shot

    /// Friends with the app open within 50 m of you: you can shoot a Sync Shot together.
    var syncShotCandidates: [UserProfile] {
        guard let me = userLocation else { return [] }
        let freshness = Date.now.addingTimeInterval(-180)
        var result = friends.filter { friend in
            guard isOnline(friend.id), let location = friendLocations[friend.id], location.updatedAt > freshness else { return false }
            return GeoClustering.haversineDistance(from: me, to: location.location) <= GeoClustering.hubRadiusMeters
        }
        if let demo {
            for friend in demo.friends where demo.onlineIDs.contains(friend.id) {
                if let location = demo.friendLocations[friend.id],
                   GeoClustering.haversineDistance(from: me, to: location.location) <= GeoClustering.hubRadiusMeters {
                    result.append(friend)
                }
            }
        }
        return result
    }

    func isDemoFriend(_ userID: UUID) -> Bool {
        demo?.friends.contains { $0.id == userID } ?? false
    }

    /// Real friends within ~100 m: invitations are checked every few seconds.
    private var hasRealFriendNearby: Bool {
        guard let me = userLocation else { return false }
        let freshness = Date.now.addingTimeInterval(-300)
        return friends.contains { friend in
            guard let location = friendLocations[friend.id], location.updatedAt > freshness else { return false }
            return GeoClustering.haversineDistance(from: me, to: location.location) <= 100
        }
    }

    fileprivate func startSyncInvitePolling() {
        syncInviteTask?.cancel()
        syncInviteTask = Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                elapsed += 4
                if self.hasRealFriendNearby || elapsed >= 28 {
                    elapsed = 0
                    await self.pollSyncInvites()
                }
            }
        }
    }

    func pollSyncInvites() async {
        guard sessionPhase == .ready, syncShotContext == nil,
              let rows = try? await dataService.fetchPendingSyncInvites() else { return }
        guard let row = rows.first(where: { !dismissedSyncInviteIDs.contains($0.id) }) else {
            if incomingSyncInvite != nil {
                withAnimation(Theme.spring) {
                    incomingSyncInvite = nil
                }
            }
            return
        }
        guard incomingSyncInvite?.id != row.id else { return }
        var sender = friends.first { $0.id == row.initiatorID }
        if sender == nil {
            sender = try? await dataService.fetchProfile(row.initiatorID)
        }
        guard let sender else { return }
        HapticManager.shared.success()
        withAnimation(Theme.spring) {
            incomingSyncInvite = IncomingSyncInvite(session: row, from: sender)
        }
    }

    /// Invites a friend nearby and opens the Sync Shot studio.
    func startSyncShot(with partner: UserProfile) async {
        HapticManager.shared.tap()
        closeViewer()
        isCameraPresented = false
        if isDemoFriend(partner.id) {
            syncShotContext = SyncShotContext(id: UUID(), partner: partner, isInitiator: true, isDemo: true)
            return
        }
        do {
            let session = try await dataService.syncInvite(partner: partner.id)
            syncShotContext = SyncShotContext(id: session.id, partner: partner, isInitiator: true, isDemo: false)
        } catch {
            HapticManager.shared.error()
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    func acceptSyncInvite() async {
        guard let invite = incomingSyncInvite else { return }
        withAnimation(Theme.spring) {
            incomingSyncInvite = nil
        }
        do {
            try await dataService.syncRespond(invite.session.id, accept: true)
            closeViewer()
            isCameraPresented = false
            syncShotContext = SyncShotContext(id: invite.session.id, partner: invite.from, isInitiator: false, isDemo: false)
        } catch {
            HapticManager.shared.error()
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
        }
    }

    func declineSyncInvite() {
        guard let invite = incomingSyncInvite else { return }
        dismissedSyncInviteIDs.insert(invite.id)
        withAnimation(Theme.spring) {
            incomingSyncInvite = nil
        }
        Task { [dataService] in
            try? await dataService.syncRespond(invite.session.id, accept: false)
        }
    }

    func closeSyncShot() {
        if let context = syncShotContext, !context.isDemo {
            Task { [dataService] in
                try? await dataService.syncCancel(context.id)
            }
        }
        syncShotContext = nil
    }

    /// Demo Sync Shot: both halves are kept on this phone only.
    @discardableResult
    func addDemoSyncShot(mine: ProcessedImage, partnerImage: ProcessedImage, partner: UserProfile, location: GeoPoint, placeName: String?) -> PhotoPin? {
        guard var scenario = demo else { return nil }
        let session = UUID()
        let now = Date.now
        func makePin(author: UserProfile, image: ProcessedImage, offset: Double) -> PhotoPin {
            let id = UUID()
            let folder = "demo/\(author.id.uuidString)/\(id.uuidString)"
            let pin = PhotoPin(
                id: id,
                author: author,
                latitude: location.latitude + offset,
                longitude: location.longitude,
                placeName: placeName,
                caption: "",
                imagePath: "\(folder)/full.jpg",
                thumbPath: "\(folder)/thumb.jpg",
                blurPath: "\(folder)/blur.jpg",
                createdAt: now,
                expiresAt: now.addingTimeInterval(PhotoPin.lifetime),
                syncSessionID: session
            )
            images[pin.imagePath] = image.fullData
            images[pin.thumbPath] = image.thumbnailData
            images[pin.blurPath] = image.blurData
            scenario.images[pin.imagePath] = image.fullData
            scenario.images[pin.thumbPath] = image.thumbnailData
            scenario.images[pin.blurPath] = image.blurData
            return pin
        }
        let myPin = makePin(author: currentUser, image: mine, offset: 0)
        let partnerPin = makePin(author: partner, image: partnerImage, offset: 0.00003)
        scenario.pins.append(contentsOf: [myPin, partnerPin])
        applyDemo(scenario)
        HapticManager.shared.success()
        return pins.first { $0.id == myPin.id }
    }

    /// Opens a single pin (and its Sync Shot partner) in the viewer.
    func openPin(_ pinID: UUID) {
        guard let pin = pins.first(where: { $0.id == pinID }) else { return }
        focusMap(on: pin.location, spanMeters: 700)
        withAnimation(Theme.spring) {
            viewerSelection = ViewerSelection(id: "pin-\(pinID.uuidString)", pinIDs: [pinID], startIndex: 0)
        }
    }

    // MARK: Geo-Capsules

    var visibleCapsules: [GeoCapsule] {
        let now = Date.now
        return capsules.filter { !$0.isExpired(at: now) }
    }

    func isOwnCapsule(_ capsule: GeoCapsule) -> Bool {
        capsule.author.id == currentUser.id
    }

    func isCapsuleOpened(_ capsule: GeoCapsule) -> Bool {
        isOwnCapsule(capsule) || openedCapsuleIDs.contains(capsule.id)
    }

    private static func capsuleImageKey(_ path: String) -> String {
        "capsule:" + path
    }

    /// The capsule photo, available once opened (or for its author).
    func capsuleImage(for capsule: GeoCapsule, thumbnail: Bool = false) -> PinImage? {
        let key = Self.capsuleImageKey(thumbnail ? capsule.thumbPath : capsule.imagePath)
        if let data = images[key] {
            return PinImage(key: key, data: data)
        }
        let fallback = Self.capsuleImageKey(capsule.thumbPath)
        return images[fallback].map { PinImage(key: fallback, data: $0) }
    }

    func capsuleSecret(for capsule: GeoCapsule) -> String? {
        capsuleSecrets[capsule.id]
    }

    func distance(to capsule: GeoCapsule) -> Double? {
        userLocation.map { GeoClustering.haversineDistance(from: $0, to: capsule.location) }
    }

    func reloadCapsules() async {
        guard sessionPhase == .ready else { return }
        guard let fetched = try? await dataService.fetchCapsules() else { return }
        let opens = (try? await dataService.fetchCapsuleOpens()) ?? []
        let me = currentUser.id
        var counts: [UUID: Int] = [:]
        var opened = demoOpenedCapsuleIDs
        for open in opens {
            if open.userID == me {
                opened.insert(open.capsuleID)
            } else {
                counts[open.capsuleID, default: 0] += 1
            }
        }
        let demoCapsules = demo?.capsules ?? []
        withAnimation(Theme.spring) {
            capsules = fetched + demoCapsules
            openedCapsuleIDs = opened
            capsuleOpenCounts = counts
        }
        for capsule in capsules where isCapsuleOpened(capsule) {
            Task { [weak self] in
                await self?.loadCapsuleContent(capsule)
            }
        }
        if let userLocation {
            checkCapsuleProximity(at: userLocation)
        }
    }

    /// Downloads the photo and the secret message of an opened capsule.
    func loadCapsuleContent(_ capsule: GeoCapsule) async {
        guard isCapsuleOpened(capsule) else { return }
        if demo?.capsuleIDs.contains(capsule.id) == true {
            if let message = demo?.capsuleSecrets[capsule.id] {
                capsuleSecrets[capsule.id] = message
            }
            for path in [capsule.imagePath, capsule.thumbPath] {
                if let data = demo?.images[path] {
                    images[Self.capsuleImageKey(path)] = data
                }
            }
            return
        }
        if capsuleSecrets[capsule.id] == nil, let message = try? await dataService.fetchCapsuleSecret(capsule.id) {
            capsuleSecrets[capsule.id] = message
        }
        for path in [capsule.thumbPath, capsule.imagePath] {
            let key = Self.capsuleImageKey(path)
            guard images[key] == nil, !imageLoadsInFlight.contains(key), !failedImagePaths.contains(key) else { continue }
            imageLoadsInFlight.insert(key)
            if let data = try? await dataService.loadCapsuleImage(path: path) {
                images[key] = data
            } else {
                failedImagePaths.insert(key)
            }
            imageLoadsInFlight.remove(key)
        }
    }

    /// Hides a Geo-Capsule at the current spot for 24 hours.
    func hideCapsule(processed: ProcessedImage, location: GeoPoint, hint: String, message: String, recipient: UserProfile?, video: URL? = nil) async throws {
        let draft = CapsuleDraft(
            image: processed,
            video: video,
            location: location,
            hint: hint.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            recipientID: recipient?.id
        )
        let capsule = try await dataService.createCapsule(draft)
        if let video, let path = capsule.videoPath {
            dataService.cacheVideo(video, key: "capsules/\(path)")
        }
        images[Self.capsuleImageKey(capsule.imagePath)] = processed.fullData
        images[Self.capsuleImageKey(capsule.thumbPath)] = processed.thumbnailData
        capsuleSecrets[capsule.id] = draft.message
        withAnimation(Theme.spring) {
            capsules.insert(capsule, at: 0)
        }
        HapticManager.shared.success()
        if let recipient {
            showToast(.success, title: String(localized: "capsule.toast.hidden.title"), subtitle: String(localized: "capsule.toast.hidden.for \(recipient.firstName)"))
        } else {
            showToast(.success, title: String(localized: "capsule.toast.hidden.title"), subtitle: String(localized: "capsule.toast.hidden.everyone"))
        }
        cameraTarget = CameraTarget(point: location, spanMeters: 800)
    }

    func deleteCapsule(_ capsule: GeoCapsule) async {
        presentedCapsule = nil
        withAnimation(Theme.spring) {
            capsules.removeAll { $0.id == capsule.id }
        }
        guard demo?.capsuleIDs.contains(capsule.id) != true else { return }
        do {
            try await dataService.deleteCapsule(capsule)
            HapticManager.shared.selection()
        } catch {
            showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
            await reloadCapsules()
        }
    }

    /// Opens every friend's capsule you are standing next to (under 20 m).
    fileprivate func checkCapsuleProximity(at point: GeoPoint) {
        let now = Date.now
        for capsule in visibleCapsules where !isCapsuleOpened(capsule) {
            guard GeoClustering.haversineDistance(from: point, to: capsule.location) <= GeoCapsule.unlockRadius else { continue }
            if let last = capsuleOpenAttempts[capsule.id], now.timeIntervalSince(last) < 15 { continue }
            capsuleOpenAttempts[capsule.id] = now
            Task { [weak self] in
                await self?.openCapsule(capsule, at: point)
            }
        }
    }

    private func openCapsule(_ capsule: GeoCapsule, at point: GeoPoint) async {
        let success: Bool
        if demo?.capsuleIDs.contains(capsule.id) == true {
            demoOpenedCapsuleIDs.insert(capsule.id)
            success = true
        } else {
            success = (try? await dataService.openCapsule(capsule.id, at: point)) ?? false
        }
        guard success else { return }
        withAnimation(Theme.spring) {
            _ = openedCapsuleIDs.insert(capsule.id)
        }
        await loadCapsuleContent(capsule)
        HapticManager.shared.capsuleOpened()
        presentedCapsule = nil
        withAnimation(Theme.spring) {
            celebratingCapsule = capsule
        }
    }

    // MARK: Demo mode

    func setDemoMode(_ enabled: Bool) {
        isDemoModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.demoDefaultsKey)
        if enabled {
            buildDemo()
            social.installDemo(currentUser: currentUser)
            HapticManager.shared.success()
            if let anchor = demo?.anchor {
                focusMap(on: anchor, spanMeters: 2_400)
            }
        } else {
            removeDemo()
            social.removeDemo()
            HapticManager.shared.selection()
        }
    }

    fileprivate func buildDemo() {
        let anchor = userLocation ?? locationService.lastFix ?? .fallback
        applyDemo(MockDataService.makeScenario(anchor: anchor, currentUser: currentUser))
    }

    /// Installs (or updates) the demo scenario on top of the real data.
    fileprivate func applyDemo(_ scenario: DemoScenario) {
        let previousPinIDs = demoPinIDs
        let previousCapsuleIDs = demo?.capsuleIDs ?? []
        demo = scenario
        demoPinIDs = scenario.pinIDs
        for (path, data) in scenario.images {
            images[path] = data
        }
        for capsule in scenario.capsules where isCapsuleOpened(capsule) || demoOpenedCapsuleIDs.contains(capsule.id) {
            if let data = scenario.images[capsule.imagePath] {
                images[Self.capsuleImageKey(capsule.imagePath)] = data
            }
            if let data = scenario.images[capsule.thumbPath] {
                images[Self.capsuleImageKey(capsule.thumbPath)] = data
            }
        }
        let serverPins = pins.filter { !previousPinIDs.contains($0.id) }
        let serverCapsules = capsules.filter { !previousCapsuleIDs.contains($0.id) }
        withAnimation(Theme.spring) {
            pins = composedPins(server: serverPins)
            capsules = serverCapsules + scenario.capsules
            recomputeClusters()
        }
        applyCrossPaths(crossPaths.filter { event in !previousPinIDs.contains(event.myPinID) } + scenario.crossPaths)
        resolveMissingPlaceNames()
    }

    fileprivate func removeDemo() {
        let pinIDs = demoPinIDs
        let capsuleIDs = demo?.capsuleIDs ?? []
        demo = nil
        demoPinIDs = []
        demoOpenedCapsuleIDs = []
        simulatedLocation = nil
        withAnimation(Theme.spring) {
            pins = attachSyncPartners(pins.filter { !pinIDs.contains($0.id) })
            capsules.removeAll { capsuleIDs.contains($0.id) }
            openedCapsuleIDs.subtract(capsuleIDs)
            crossPaths.removeAll { pinIDs.contains($0.myPinID) || pinIDs.contains($0.friendPinID) }
            recomputeClusters()
        }
        if syncShotContext?.isDemo == true {
            syncShotContext = nil
        }
        Task { [weak self] in
            await self?.refreshUserLocation()
        }
    }

    /// Demo control: moves your position next to the demo capsule to test the 20 m unlock.
    func simulateCapsuleApproach() {
        if demo == nil {
            setDemoMode(true)
        }
        guard let scenario = demo, let capsule = scenario.capsules.first else { return }
        // Make the test repeatable: close the capsule again first.
        demoOpenedCapsuleIDs.remove(capsule.id)
        openedCapsuleIDs.remove(capsule.id)
        capsuleOpenAttempts[capsule.id] = nil
        let target = MockDataService.point(from: capsule.location, meters: 8, bearing: 30)
        simulatedLocation = target
        userLocation = target
        isFriendsDrawerPresented = false
        showToast(.info, title: String(localized: "demo.toast.walking.title"), subtitle: String(localized: "demo.toast.walking.subtitle"))
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.focusMap(on: target, spanMeters: 420)
            try? await Task.sleep(for: .milliseconds(1_300))
            self?.checkCapsuleProximity(at: target)
        }
    }

    /// Demo control: goes back to the real GPS position.
    func endLocationSimulation() {
        simulatedLocation = nil
        Task { [weak self] in
            await self?.refreshUserLocation()
            if let point = self?.userLocation {
                self?.focusMap(on: point, spanMeters: 1_800)
            }
        }
    }

    /// Demo control: creates a cross-path with a demo friend right where you are.
    func generateDemoCrossPath() {
        if demo == nil {
            setDemoMode(true)
        }
        guard var scenario = demo else { return }
        let center = userLocation ?? scenario.anchor
        guard let event = MockDataService.addCrossPath(to: &scenario, near: center, currentUser: currentUser) else { return }
        dismissedCrossPathIDs.remove(event.id)
        applyDemo(scenario)
        isFriendsDrawerPresented = false
        HapticManager.shared.crossPath()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.focusMap(on: event.location, spanMeters: 520)
        }
    }
}

// MARK: - Groups on the map & street-following trail

extension AppState {
    /// Friends this close to each other (or to you) are "together".
    nonisolated static let togetherDistance: Double = 35

    /// Friends standing with you right now: drawn next to your avatar.
    var companions: [UserProfile] {
        guard let me = userLocation else { return [] }
        let freshness = Date.now.addingTimeInterval(-600)
        return visibleFriendLocations
            .filter { $0.location.updatedAt > freshness && GeoClustering.haversineDistance(from: me, to: $0.location.location) <= Self.togetherDistance }
            .map(\.profile)
    }

    /// Other friends on the map, grouped when they stand together.
    var friendGroupsOnMap: [FriendGroupOnMap] {
        let companionIDs = Set(companions.map(\.id))
        let remaining = visibleFriendLocations.filter { !companionIDs.contains($0.profile.id) }
        var groups: [[FriendOnMap]] = []
        for friend in remaining {
            if let index = groups.firstIndex(where: { group in
                group.contains { GeoClustering.haversineDistance(from: $0.location.location, to: friend.location.location) <= Self.togetherDistance }
            }) {
                groups[index].append(friend)
            } else {
                groups.append([friend])
            }
        }
        return groups.map { FriendGroupOnMap(members: $0) }
    }

    /// Your trail (oldest pin first), following the streets once directions are loaded.
    var myTrailPoints: [GeoPoint] {
        if !myRoutePoints.isEmpty { return myRoutePoints }
        return myTrailPins.map(\.location)
    }

    private var myTrailPins: [PhotoPin] {
        activePins
            .filter { isOwn($0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Recomputes the street route between your pins when they change.
    fileprivate func updateMyRoute() {
        let pins = myTrailPins
        let ids = pins.map(\.id)
        guard ids != routedPinIDs else { return }
        routedPinIDs = ids
        routeTask?.cancel()
        guard pins.count >= 2 else {
            myRoutePoints = []
            return
        }
        let stops = pins.map(\.location)
        routeTask = Task { [weak self] in
            var points: [GeoPoint] = []
            for index in stops.indices.dropFirst() {
                let from = stops[index - 1]
                let to = stops[index]
                let key = String(format: "%.5f,%.5f>%.5f,%.5f", from.latitude, from.longitude, to.latitude, to.longitude)
                var segment = self?.routeCache[key]
                if segment == nil {
                    segment = await Self.streetRoute(from: from, to: to)
                    if Task.isCancelled { return }
                    self?.routeCache[key] = segment
                }
                let resolved = segment ?? [from, to]
                points.append(contentsOf: points.isEmpty ? resolved : Array(resolved.dropFirst()))
            }
            guard !Task.isCancelled, let self else { return }
            withAnimation(Theme.spring) {
                self.myRoutePoints = points
            }
        }
    }

    /// Walking directions between two pins (driving when they are far apart).
    nonisolated static func streetRoute(from: GeoPoint, to: GeoPoint) async -> [GeoPoint]? {
        let distance = GeoClustering.haversineDistance(from: from, to: to)
        guard distance > 25 else { return [from, to] }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.transportType = distance > 4_000 ? .automobile : .walking
        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else { return nil }
        let polyline = route.polyline
        let count = polyline.pointCount
        guard count >= 2 else { return nil }
        let mapPoints = polyline.points()
        var result: [GeoPoint] = [from]
        for index in 0..<count {
            result.append(GeoPoint(mapPoints[index].coordinate))
        }
        result.append(to)
        return result
    }
}
