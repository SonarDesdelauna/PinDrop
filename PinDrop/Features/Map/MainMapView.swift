import MapKit
import SwiftUI

/// Dark social map with floating HUD, bottom dock, hub clustering and the Stories viewer overlay.
struct MainMapView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationService.self) private var locationService
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var heroNamespace
    /// Center of the visible map, used to save a place where the map is pointing.
    @State private var mapCenter: GeoPoint?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnUser = false
    /// Above this camera altitude the map switches to the photorealistic 3D globe.
    @State private var isGlobeMode = false
    @State private var selectedPublicPlace: PublicPlace?
    /// Map scale and rotation, used to keep other annotations from covering your avatar.
    @State private var metersPerPoint: Double = 0
    @State private var mapHeading: Double = 0
    @State private var mapHeight: CGFloat = 0
    /// Last camera reported by the map, used by the edge zoom gesture.
    @State private var lastCamera: MapCamera?
    /// Edge zoom: the camera when the gesture started and where the finger was.
    @State private var edgeZoomStart: MapCamera?
    @State private var edgeZoomOriginY: CGFloat = 0
    @State private var edgeZoomDelta: CGFloat = 0
    @State private var edgeZoomSide: HorizontalEdge?
    private static let globeAltitude: Double = 1_200_000
    /// Zoomed out further than this (meters per screen point) only your dot is drawn.
    private static let farZoomScale: Double = 1_200
    /// Your own photo is drawn on your avatar while you are this close to it.
    private static let ownPinMergeDistance: Double = 150
    /// Below this speed you are considered still (m/s).
    private static let movingSpeed: Double = 1.5

    var body: some View {
        @Bindable var state = appState
        @Bindable var social = appState.social

        ZStack {
            mapLayer

            edgeZoomStrips

            if isGlobeMode {
                OrbitingObjectsView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            overlayChrome

            if let selection = appState.viewerSelection {
                PinDetailViewer(selection: selection, namespace: heroNamespace)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity
                    ))
                    .zIndex(10)
            }

            if let capsule = appState.celebratingCapsule {
                CapsuleUnlockCelebrationView(capsule: capsule)
                    .transition(.opacity)
                    .zIndex(15)
            }

            toastLayer
                .zIndex(20)
        }
        .background(Theme.obsidian)
        .animation(Theme.spring, value: appState.celebratingCapsule)
        .animation(Theme.spring, value: appState.viewerSelection)
        .animation(Theme.spring, value: appState.toast)
        .fullScreenCover(isPresented: $state.isCameraPresented) {
            CameraStudioView()
        }
        .fullScreenCover(item: storyViewerBinding) { start in
            StoryViewerView(startAuthorID: start.id)
        }
        .sheet(isPresented: $social.isChatListPresented) {
            ChatListView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .fullScreenCover(item: $state.syncShotContext) { context in
            SyncShotStudioView(context: context)
        }
        .sheet(item: $state.presentedCapsule) { capsule in
            GeoCapsuleSheet(capsule: capsule)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(isPresented: $state.isRecapPresented) {
            NightRecapSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(isPresented: $state.isPlacesPresented) {
            PlacesView(
                onSelect: { place in
                    appState.isPlacesPresented = false
                    appState.focusMap(on: place.location, spanMeters: 700)
                },
                onAdd: {
                    appState.isPlacesPresented = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        appState.isAddPlacePresented = true
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(isPresented: $state.isAddPlacePresented) {
            PlaceEditorView(mode: .add, userLocation: appState.userLocation, mapCenter: mapCenter)
                .presentationDetents([.large])
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(isPresented: $state.isFriendsDrawerPresented) {
            FriendsDrawerView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(isPresented: $state.isNotificationsPresented) {
            NotificationsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(item: $state.presentedProfile) { user in
            ProfileSheet(user: user)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(isPresented: $state.isLocationRemindersPresented) {
            LocationRemindersView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .sheet(item: $selectedPublicPlace) { place in
            PublicPlaceSheet(place: place)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(Theme.Radius.sheet)
        }
        .onChange(of: appState.cameraTarget) { _, target in
            guard let target else { return }
            withAnimation(Theme.spring) {
                cameraPosition = .region(region(around: target.point, spanMeters: target.spanMeters))
            }
        }
        .onChange(of: appState.userLocation) { _, location in
            guard let location, !hasCenteredOnUser, appState.viewerSelection == nil else { return }
            hasCenteredOnUser = true
            withAnimation(Theme.spring) {
                cameraPosition = .region(region(around: location, spanMeters: 2_600))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                appState.startLiveTracking()
            } else if phase == .background {
                appState.stopLiveTracking()
            }
        }
        .onDisappear {
            appState.stopLiveTracking()
        }
        .onAppear {
            appState.startLiveTracking()
            if let location = appState.userLocation, !hasCenteredOnUser {
                hasCenteredOnUser = true
                cameraPosition = .region(region(around: location, spanMeters: 2_600))
            }
        }
    }

    // MARK: - Derived state

    private var currentSpeed: Double? {
        guard let speed = locationService.speed, speed >= Self.movingSpeed else { return nil }
        return speed
    }

    /// Your active photos near you, newest first: they are drawn on your avatar.
    private var mergedOwnPins: [PhotoPin] {
        guard let userLocation = appState.userLocation else { return [] }
        return appState.activePins
            .filter { appState.isOwn($0) && !appState.isDemoPin($0) && !$0.isSyncShot && GeoClustering.haversineDistance(from: $0.location, to: userLocation) <= Self.ownPinMergeDistance }
            .sorted { $0.expiresAt > $1.expiresAt }
    }

    /// Clusters drawn as separate pins, without your photos that are merged into your avatar.
    private var visibleClusters: [PinCluster] {
        let mergedIDs = Set(mergedOwnPins.map(\.id))
        guard !mergedIDs.isEmpty else { return appState.clusters }
        return appState.clusters.compactMap { cluster in
            guard cluster.pins.contains(where: { mergedIDs.contains($0.id) }) else { return cluster }
            let remaining = cluster.pins.filter { !mergedIDs.contains($0.id) }
            guard !remaining.isEmpty else { return nil }
            return PinCluster(pins: remaining, center: cluster.center, placeName: cluster.placeName)
        }
    }

    /// Everything is drawn at its true position. What would overlap on screen is merged
    /// (friends become one Bump-style group, things under your avatar join your avatar)
    /// or hidden until you zoom in (place labels), like the system map does with labels.
    private struct MapLayout {
        var friendGroups: [FriendGroupOnMap] = []
        var companions: [UserProfile] = []
        var clusters: [PinCluster] = []
        var pinsUnderMe: [PhotoPin] = []
        var capsules: [GeoCapsule] = []
        var capsulesUnderMe: [GeoCapsule] = []
        var places: [SavedPlace] = []
        var publicPlaces: [PublicPlace] = []
    }

    /// Meters per screen point, rounded to quarter zoom steps so the layout only changes
    /// when the zoom really changes (no flicker while pinching).
    private var layoutScale: Double {
        guard metersPerPoint > 0 else { return 0 }
        return pow(2, (log2(metersPerPoint) * 4).rounded() / 4)
    }

    /// Very far out (or on the globe) the map shows only your position, like Apple Maps.
    private var isFarZoom: Bool {
        layoutScale > Self.farZoomScale
    }

    private var mapLayout: MapLayout {
        let scale = layoutScale
        var layout = MapLayout()
        guard !isFarZoom else { return layout }
        var occupied: [(point: GeoPoint, radius: Double)] = []
        let me = appState.userLocation
        let meRadius: Double = 40

        func screenDistance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
            guard scale > 0 else { return .greatestFiniteMagnitude }
            return GeoClustering.haversineDistance(from: a, to: b) / scale
        }
        func isUnderMe(_ point: GeoPoint, radius: Double) -> Bool {
            guard let me else { return false }
            return screenDistance(me, point) < meRadius + radius
        }
        func fits(_ point: GeoPoint, radius: Double) -> Bool {
            occupied.allSatisfy { screenDistance($0.point, point) >= $0.radius + radius }
        }

        if let me { occupied.append((me, meRadius)) }

        // Friends: with you → next to your avatar; close to each other on screen → one group.
        var companions = appState.companions
        let companionIDs = Set(companions.map(\.id))
        let mergeMeters = max(AppState.togetherDistance, 46 * scale)
        var groups: [[FriendOnMap]] = []
        for friend in appState.visibleFriendLocations where !companionIDs.contains(friend.profile.id) {
            if isUnderMe(friend.location.location, radius: 18) {
                companions.append(friend.profile)
                continue
            }
            if let index = groups.firstIndex(where: { group in
                group.contains { GeoClustering.haversineDistance(from: $0.location.location, to: friend.location.location) <= mergeMeters }
            }) {
                groups[index].append(friend)
            } else {
                groups.append([friend])
            }
        }
        layout.companions = companions
        layout.friendGroups = groups.map { FriendGroupOnMap(members: $0) }
        for group in layout.friendGroups {
            occupied.append((group.location, 22 + Double(min(group.members.count, 5) - 1) * 10))
        }

        // Photo pins: under your avatar → shown on it; otherwise always drawn.
        for cluster in visibleClusters {
            if isUnderMe(cluster.center, radius: 24) {
                layout.pinsUnderMe.append(contentsOf: cluster.pins)
            } else {
                layout.clusters.append(cluster)
                occupied.append((cluster.center, 26))
            }
        }

        // Capsules: under your avatar → a crystal badge on it; hidden if covered by others.
        for capsule in appState.visibleCapsules {
            if isUnderMe(capsule.location, radius: 18) {
                layout.capsulesUnderMe.append(capsule)
            } else if fits(capsule.location, radius: 20) {
                layout.capsules.append(capsule)
                occupied.append((capsule.location, 20))
            }
        }

        // Place labels are the lowest priority: shown only where there is room.
        for place in visiblePlaces where fits(place.location, radius: 30) {
            layout.places.append(place)
            occupied.append((place.location, 30))
        }
        for place in appState.visiblePublicPlaces where fits(place.location, radius: 30) {
            layout.publicPlaces.append(place)
            occupied.append((place.location, 30))
        }
        return layout
    }

    /// Saved places drawn on the map: the one you are in is shown on your avatar instead.
    private var visiblePlaces: [SavedPlace] {
        guard let current = appState.currentPlace else { return appState.places }
        return appState.places.filter { $0.id != current.id }
    }

    /// Friends' capsules still locked and close enough to show their 20 m circle.
    private var nearbyLockedCapsules: [GeoCapsule] {
        guard let user = appState.userLocation else { return [] }
        return appState.visibleCapsules.filter { capsule in
            !appState.isCapsuleOpened(capsule)
                && GeoClustering.haversineDistance(from: user, to: capsule.location) <= GeoCapsule.circleVisibleDistance
        }
    }

    private func onlineIDs(for users: [UserProfile]) -> Set<UUID> {
        Set(users.map(\.id).filter { appState.isOnline($0) })
    }

    /// Opens a friend's profile (a nearby demo friend starts a Sync Shot instead).
    private func openFriend(_ friend: UserProfile) {
        HapticManager.shared.tap()
        if appState.isDemoFriend(friend.id) {
            if appState.syncShotCandidates.contains(where: { $0.id == friend.id }) {
                Task { await appState.startSyncShot(with: friend) }
            }
        } else {
            appState.openProfile(friend)
        }
    }

    private func openOwnPins(_ pins: [PhotoPin]) {
        guard let first = pins.first else { return }
        HapticManager.shared.pinTap()
        appState.openViewer(for: PinCluster(pins: pins, center: first.location), startingAt: first.id)
    }

    // MARK: - Map

    // MARK: - Edge zoom

    /// One-thumb zoom: start at the left or right edge, slide a little toward the center,
    /// then move up to zoom in or down to zoom out.
    private var edgeZoomStrips: some View {
        HStack(spacing: 0) {
            edgeZoomStrip(.leading)
            Spacer(minLength: 0)
            edgeZoomStrip(.trailing)
        }
        .padding(.top, 150)
        .padding(.bottom, 170)
        .ignoresSafeArea(edges: .horizontal)
    }

    private func edgeZoomStrip(_ side: HorizontalEdge) -> some View {
        Color.clear
            .frame(width: 26)
            .contentShape(Rectangle())
            .overlay(alignment: side == .leading ? .leading : .trailing) {
                if edgeZoomSide == side {
                    edgeZoomIndicator
                        .offset(x: side == .leading ? 30 : -30)
                        .position(x: side == .leading ? 13 : 13, y: edgeZoomOriginY + edgeZoomDelta)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        if edgeZoomStart == nil {
                            let inward = side == .leading ? value.translation.width : -value.translation.width
                            // Slide toward the center first; a vertical-only drag does nothing.
                            guard inward >= 12, let camera = lastCamera else { return }
                            edgeZoomStart = camera
                            edgeZoomOriginY = value.location.y
                            edgeZoomDelta = 0
                            withAnimation(Theme.spring) { edgeZoomSide = side }
                            HapticManager.shared.selection()
                        }
                        guard let start = edgeZoomStart else { return }
                        let delta = value.location.y - edgeZoomOriginY
                        edgeZoomDelta = delta
                        // Up (negative delta) zooms in: every 110 pt doubles the zoom.
                        let distance = min(max(start.distance * pow(2, Double(delta) / 110), 120), 30_000_000)
                        cameraPosition = .camera(MapCamera(
                            centerCoordinate: start.centerCoordinate,
                            distance: distance,
                            heading: start.heading,
                            pitch: start.pitch
                        ))
                    }
                    .onEnded { _ in
                        if edgeZoomStart != nil {
                            HapticManager.shared.selection()
                        }
                        edgeZoomStart = nil
                        withAnimation(Theme.spring) { edgeZoomSide = nil }
                    }
            )
    }

    private var edgeZoomIndicator: some View {
        Image(systemName: edgeZoomDelta <= 0 ? "plus.magnifyingglass" : "minus.magnifyingglass")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Theme.electricViolet)
            .frame(width: 44, height: 44)
            .glassCircle()
            .allowsHitTesting(false)
    }

    private var mapLayer: some View {
        let farZoom = isFarZoom
        let skidSegments = farZoom ? [] : SkidMarks.segments(trail: appState.trail, current: currentSpeed == nil ? nil : appState.displayLocation)
        let layout = mapLayout
        return Map(position: $cameraPosition, interactionModes: .all) {
            // Your evening trail only (friends never see it), following the streets.
            let trailPoints = farZoom ? [] : appState.myTrailPoints
            if trailPoints.count >= 2 {
                let coordinates = trailPoints.map(\.coordinate)
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        Theme.neonPurple.opacity(0.3),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
                    )
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        LinearGradient(colors: [Theme.electricViolet, Theme.neonPurple], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 6])
                    )
            }

            ForEach(farZoom ? [] : nearbyLockedCapsules) { capsule in
                MapCircle(center: capsule.coordinate, radius: GeoCapsule.unlockRadius)
                    .foregroundStyle(Color(hex: 0xF59E0B).opacity(0.16))
                    .stroke(Color(hex: 0xF59E0B).opacity(0.85), lineWidth: 1.5)
            }

            // A short glowing comet tail behind you while you move.
            ForEach(skidSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Theme.neonPurple.opacity(0.35 * segment.fade),
                        style: StrokeStyle(lineWidth: 4 + 10 * segment.fade, lineCap: .round, lineJoin: .round)
                    )
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Theme.electricViolet.opacity(0.25 + 0.7 * segment.fade),
                        style: StrokeStyle(lineWidth: 1.5 + 4 * segment.fade, lineCap: .round, lineJoin: .round)
                    )
            }

            ForEach(layout.places) { place in
                Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                    Button {
                        HapticManager.shared.tap()
                        appState.isPlacesPresented = true
                    } label: {
                        PlaceAnnotationView(place: place, isCurrent: false)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .annotationTitles(.hidden)
            }

            ForEach(layout.publicPlaces) { place in
                Annotation(place.name, coordinate: place.location.coordinate, anchor: .bottom) {
                    Button {
                        HapticManager.shared.tap()
                        selectedPublicPlace = place
                    } label: {
                        PublicPlaceAnnotationView(place: place)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .annotationTitles(.hidden)
            }

            ForEach(layout.friendGroups) { group in
                Annotation(group.profiles.map(\.displayName).joined(separator: ", "), coordinate: group.location.coordinate, anchor: .bottom) {
                    if group.profiles.count == 1, let friend = group.profiles.first {
                        Button {
                            openFriend(friend)
                        } label: {
                            FriendGroupAnnotationView(users: group.profiles, updatedAt: group.updatedAt, onlineIDs: onlineIDs(for: group.profiles), music: group.profiles.count == 1 ? group.profiles.first.flatMap { appState.liveMusic(for: $0.id) } : nil)
                        }
                        .buttonStyle(PressableButtonStyle())
                    } else {
                        Menu {
                            ForEach(group.profiles) { friend in
                                Button {
                                    openFriend(friend)
                                } label: {
                                    Text(verbatim: friend.displayName)
                                }
                            }
                        } label: {
                            FriendGroupAnnotationView(users: group.profiles, updatedAt: group.updatedAt, onlineIDs: onlineIDs(for: group.profiles), music: group.profiles.count == 1 ? group.profiles.first.flatMap { appState.liveMusic(for: $0.id) } : nil)
                        }
                    }
                }
                .annotationTitles(.hidden)
            }

            ForEach(layout.capsules) { capsule in
                Annotation("", coordinate: capsule.coordinate, anchor: .bottom) {
                    Button {
                        HapticManager.shared.tap()
                        appState.presentedCapsule = capsule
                    } label: {
                        GeoCapsuleAnnotationView(
                            author: capsule.author,
                            isOpened: appState.isCapsuleOpened(capsule),
                            isOwn: appState.isOwnCapsule(capsule),
                            distanceText: appState.distanceText(to: capsule.location)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .annotationTitles(.hidden)
            }

            if !farZoom, let event = appState.activeCrossPath {
                Annotation("", coordinate: event.location.coordinate, anchor: .center) {
                    CrossPathMarkerView(friend: event.friend)
                }
                .annotationTitles(.hidden)
            }

            ForEach(layout.clusters) { cluster in
                Annotation(appState.placeName(for: cluster) ?? "", coordinate: cluster.center.coordinate, anchor: .bottom) {
                    annotationView(for: cluster)
                }
                .annotationTitles(.hidden)
            }

            if let shown = appState.displayLocation {
                let ownPins = mergedOwnPins
                let ownPin = ownPins.first
                Annotation("", coordinate: shown.coordinate, anchor: .center) {
                    if farZoom {
                        MyLocationDotView()
                    } else {
                    MyLocationAnnotationView(
                        user: appState.currentUser,
                        ownPin: ownPin,
                        extraPhotoCount: max(0, ownPins.count - 1),
                        ownThumbnail: ownPin.flatMap { appState.thumbnail(for: $0) },
                        place: appState.currentPlace,
                        since: appState.presenceSince,
                        speed: currentSpeed,
                        companions: layout.companions,
                        onlineIDs: onlineIDs(for: layout.companions),
                        music: appState.liveMusic(for: appState.currentUser.id),
                        nearbyPin: layout.pinsUnderMe.first,
                        nearbyCount: layout.pinsUnderMe.count,
                        nearbyThumbnail: layout.pinsUnderMe.first.flatMap { appState.thumbnail(for: $0) },
                        nearbyLocked: layout.pinsUnderMe.first.map { appState.isLocked($0) } ?? false,
                        capsuleCount: layout.capsulesUnderMe.count,
                        onOpenNearby: { openOwnPins(layout.pinsUnderMe) },
                        onOpenCapsule: {
                            HapticManager.shared.tap()
                            appState.presentedCapsule = layout.capsulesUnderMe.first
                        },
                        onOpenPhoto: { _ in openOwnPins(ownPins) }
                    )
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(mapStyle)
        .mapControls {}
        .onMapCameraChange(frequency: .continuous) { context in
            lastCamera = context.camera
            mapHeading = context.camera.heading
            if mapHeight > 0 {
                metersPerPoint = context.region.span.latitudeDelta * 111_320 / Double(mapHeight)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            mapCenter = GeoPoint(context.region.center)
            let shouldShowGlobe = context.camera.distance > Self.globeAltitude
            if shouldShowGlobe != isGlobeMode {
                withAnimation(.easeInOut(duration: 0.45)) {
                    isGlobeMode = shouldShowGlobe
                }
            }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            mapHeight = height
        }
    }

    @ViewBuilder
    private func annotationView(for cluster: PinCluster) -> some View {
        let inactiveHeroIDs = Set(appState.viewerSelection?.pinIDs ?? [])
        if cluster.isHub {
            Button {
                HapticManager.shared.clusterTap()
                appState.openViewer(for: cluster, startingAt: nil)
            } label: {
                ClusterAnnotationView(
                    cluster: cluster,
                    thumbnails: Dictionary(uniqueKeysWithValues: cluster.pins.compactMap { pin in
                        appState.thumbnail(for: pin).map { (pin.id, $0) }
                    }),
                    placeName: appState.placeName(for: cluster),
                    currentUserID: appState.currentUser.id,
                    isAppUnlocked: appState.isUnlocked,
                    unlockedPinIDs: appState.crossPathUnlockedPinIDs,
                    distanceText: appState.distanceText(to: cluster.center),
                    namespace: heroNamespace,
                    inactiveHeroPinIDs: inactiveHeroIDs
                )
            }
            .buttonStyle(PressableButtonStyle())
        } else if let pin = cluster.leadPin {
            Button {
                HapticManager.shared.pinTap()
                appState.openViewer(for: cluster, startingAt: pin.id)
            } label: {
                PinAnnotationView(
                    pin: pin,
                    thumbnail: appState.thumbnail(for: pin),
                    isOwn: appState.isOwn(pin),
                    isLocked: appState.isLocked(pin),
                    distanceText: appState.isOwn(pin) ? nil : appState.distanceText(to: pin.location),
                    namespace: heroNamespace,
                    isHeroActive: !inactiveHeroIDs.contains(pin.id),
                    isOnline: !appState.isOwn(pin) && appState.isOnline(pin.author.id)
                )
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    // MARK: - HUD & dock

    private var overlayChrome: some View {
        VStack(spacing: 12) {
            topHUD
            if let invite = appState.incomingSyncInvite {
                SyncInviteBanner(
                    invite: invite,
                    onAccept: {
                        HapticManager.shared.tap()
                        Task { await appState.acceptSyncInvite() }
                    },
                    onDecline: {
                        HapticManager.shared.selection()
                        appState.declineSyncInvite()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if let event = appState.activeCrossPath {
                CrossPathBannerView(
                    event: event,
                    onCompare: {
                        appState.openCrossPath(event)
                    },
                    onDismiss: {
                        HapticManager.shared.selection()
                        appState.dismissCrossPath(event)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            let candidates = appState.syncShotCandidates
            if !candidates.isEmpty {
                SyncShotPill(candidates: candidates) { friend in
                    Task { await appState.startSyncShot(with: friend) }
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            locationBanners
            if appState.lockedFriendPinCount > 0 {
                lockedBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            dock
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(Theme.spring, value: appState.isUnlocked)
        .animation(Theme.spring, value: currentSpeed == nil)
        .animation(Theme.spring, value: appState.isAlwaysBannerDismissed)
        .animation(Theme.spring, value: appState.isFriendsLocationBannerDismissed)
        .animation(Theme.spring, value: appState.activeCrossPath)
        .animation(Theme.spring, value: appState.incomingSyncInvite)
        .animation(Theme.spring, value: appState.syncShotCandidates.map(\.id))
    }

    /// Profile views centered at the top, avatar and bell on the right, speed on the left
    /// while moving.
    private var topHUD: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    if isFarZoom {
                        Spacer(minLength: 0)
                    } else {
                        StoriesBarView()
                            .padding(.leading, -16)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    viewsPill(compact: true)
                        .padding(.top, 14)
                        .layoutPriority(1)
                }
                if let speed = currentSpeed {
                    speedPill(speed)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            VStack(spacing: 10) {
                profileButton
                bellButton
                chatButton
                recapButton
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: isFarZoom)
    }

    /// The story viewer is open while a starting person is set.
    private var storyViewerBinding: Binding<StoryViewerStart?> {
        Binding(
            get: { appState.social.storyViewerStart.map { StoryViewerStart(id: $0) } },
            set: { appState.social.storyViewerStart = $0?.id }
        )
    }

    /// Opens the conversations, with the unread count.
    private var chatButton: some View {
        let unread = appState.social.totalUnread
        return Button {
            HapticManager.shared.tap()
            appState.social.isChatListPresented = true
        } label: {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.neonPurple)
                .symbolEffect(.bounce, value: unread)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .glassCircle(interactive: true)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(min(unread, 99), format: .number)
                            .font(Theme.roundedFixed(11, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentGradient))
                            .offset(x: 4, y: -3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text("chat.title"))
        .accessibilityValue(Text("notifications.unread \(unread)"))
    }

    /// "N profile views", like the counter next to the avatar.
    private func viewsPill(compact: Bool) -> some View {
        Button {
            HapticManager.shared.tap()
            appState.isFriendsDrawerPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(Theme.neonPurple)
                if compact {
                    Text(appState.currentUser.viewCount, format: .number)
                        .foregroundStyle(Theme.neonPurple)
                        .contentTransition(.numericText())
                } else {
                    Text(Self.viewsLabel(appState.currentUser.viewCount))
                        .contentTransition(.numericText())
                }
            }
            .font(Theme.rounded(.footnote, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .contentShape(Capsule())
            .glassCapsule(interactive: true)
            .fixedSize()
        }
        .buttonStyle(PressableButtonStyle())
        .animation(Theme.spring, value: appState.currentUser.viewCount)
        .accessibilityLabel(Text("hud.profileViews \(appState.currentUser.viewCount)"))
    }

    /// "N profile views" with only the number in the accent color.
    private static func viewsLabel(_ count: Int) -> AttributedString {
        var label = AttributedString(localized: "hud.profileViews \(count)")
        label.foregroundColor = Theme.textPrimary
        let number = count.formatted(.number)
        if let range = label.range(of: number) {
            label[range].foregroundColor = Theme.neonPurple
        }
        return label
    }

    private func speedPill(_ speed: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(Theme.neonPurple)
            Text(verbatim: LocaleFormatter.speed(metersPerSecond: speed))
                .contentTransition(.numericText())
        }
        .font(Theme.rounded(.subheadline, weight: .heavy))
        .foregroundStyle(Theme.textPrimary)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCapsule()
        .fixedSize()
        .animation(.snappy, value: Int(speed * 3.6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("hud.speed \(LocaleFormatter.speed(metersPerSecond: speed))"))
    }

    private var profileButton: some View {
        Button {
            HapticManager.shared.tap()
            appState.isFriendsDrawerPresented = true
        } label: {
            AvatarBadge(user: appState.currentUser, size: 42)
                .padding(3)
                .overlay {
                    Circle().strokeBorder(appState.isUnlocked ? AnyShapeStyle(Theme.emeraldGradient) : AnyShapeStyle(Theme.accentGradient), lineWidth: 2)
                }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text("a11y.profile"))
    }

    private var bellButton: some View {
        let unread = appState.unreadNotificationCount
        return Button {
            HapticManager.shared.tap()
            appState.isNotificationsPresented = true
        } label: {
            Image(systemName: unread > 0 ? "bell.badge.fill" : "bell.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.neonPurple)
                .symbolEffect(.bounce, value: unread)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .glassCircle(interactive: true)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(min(unread, 99), format: .number)
                            .font(Theme.roundedFixed(11, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentGradient))
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text("notifications.title"))
        .accessibilityValue(Text("notifications.unread \(unread)"))
    }

    /// Opens the evening recap (stats + shareable story card).
    private var recapButton: some View {
        Button {
            HapticManager.shared.tap()
            appState.isRecapPresented = true
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("recap.hud")
                    .font(Theme.roundedFixed(9, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Theme.neonPurple)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .glassCircle(interactive: true)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text("recap.title"))
    }

    /// Red warnings shown every time the app is opened: your location is only "While Using",
    /// or some friends don't share theirs with "Always".
    @ViewBuilder
    private var locationBanners: some View {
        if locationService.authorizationStatus == .authorizedWhenInUse, !appState.isAlwaysBannerDismissed {
            LocationWarningBanner(
                title: "locationBanner.always.title",
                message: Text("locationBanner.always.body"),
                actionTitle: "locationBanner.always.action",
                action: {
                    HapticManager.shared.tap()
                    appState.requestAlwaysLocation()
                },
                onDismiss: {
                    withAnimation(Theme.spring) {
                        appState.isAlwaysBannerDismissed = true
                    }
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !appState.friendsWithoutAlways.isEmpty, !appState.isFriendsLocationBannerDismissed {
            LocationWarningBanner(
                title: "locationBanner.friends.title \(appState.friendsWithoutAlways.count)",
                message: Text("locationBanner.friends.body"),
                actionTitle: "locationBanner.friends.action",
                action: {
                    HapticManager.shared.tap()
                    appState.isLocationRemindersPresented = true
                },
                onDismiss: {
                    withAnimation(Theme.spring) {
                        appState.isFriendsLocationBannerDismissed = true
                    }
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var lockedBanner: some View {
        Button {
            HapticManager.shared.tap()
            appState.presentCamera()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 46, height: 46)
                        .glow(Theme.electricViolet, radius: 10)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("locked.title")
                        .font(Theme.text(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("locked.subtitle \(appState.lockedFriendPinCount)")
                        .font(Theme.text(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .shimmer()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassCard(cornerRadius: 24)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
    }

    private var dock: some View {
        HStack(spacing: 0) {
            dockButton(systemImage: "location.fill", label: "dock.recenter", badge: 0) {
                recenter()
            }
            Spacer(minLength: 6)
            dockButton(systemImage: "star.fill", label: "dock.places", badge: 0) {
                HapticManager.shared.tap()
                appState.isPlacesPresented = true
            }
            Spacer(minLength: 6)
            shutterButton
            Spacer(minLength: 6)
            dockButton(systemImage: "mappin.and.ellipse", label: "dock.addPlace", badge: 0) {
                HapticManager.shared.tap()
                appState.isAddPlacePresented = true
            }
            Spacer(minLength: 6)
            dockButton(systemImage: "person.2.fill", label: "dock.friends", badge: appState.activeFriendsCount + appState.pendingRequestCount) {
                HapticManager.shared.tap()
                appState.isFriendsDrawerPresented = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassCapsule()
        .padding(.horizontal, 6)
    }

    private func dockButton(systemImage: String, label: LocalizedStringKey, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge, format: .number)
                            .font(Theme.roundedFixed(11, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.emerald))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(label))
    }

    private var shutterButton: some View {
        Button {
            HapticManager.shared.tap()
            appState.presentCamera()
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 31, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 58, height: 58)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
        .accessibilityLabel(Text("dock.drop"))
    }

    // MARK: - Toasts

    private var toastLayer: some View {
        VStack {
            if let toast = appState.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        appState.dismissToast()
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: - Camera helpers

    private func recenter() {
        HapticManager.shared.selection()
        let target = appState.userLocation ?? appState.ownActivePin?.location
        if let target {
            withAnimation(Theme.spring) {
                cameraPosition = .region(region(around: target, spanMeters: 1_800))
            }
        } else {
            withAnimation(Theme.spring) {
                cameraPosition = .automatic
            }
        }
        Task { await appState.refreshUserLocation() }
    }

    /// Muted 3D city map up close; satellite imagery on a realistic globe when zoomed out,
    /// like Apple Maps.
    private var mapStyle: MapStyle {
        if isGlobeMode {
            .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: false)
        } else {
            .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
        }
    }

    private func region(around point: GeoPoint, spanMeters: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: point.coordinate, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    }
}

/// Glass toast banner.
struct ToastView: View {
    let toast: ToastMessage

    private var tint: Color {
        switch toast.style {
        case .success: Theme.emerald
        case .info: Theme.neonPurple
        case .ping: Theme.emerald
        case .warning: Theme.warning
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: toast.title)
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle = toast.subtitle {
                    Text(verbatim: subtitle)
                        .font(Theme.text(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassCard(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }
}

/// Identifiable wrapper for the person whose stories the viewer opens on.
struct StoryViewerStart: Identifiable, Hashable {
    let id: UUID
}
