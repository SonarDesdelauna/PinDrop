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
    private static let globeAltitude: Double = 1_200_000
    /// Your own photo is drawn on your avatar while you are this close to it.
    private static let ownPinMergeDistance: Double = 150
    /// Below this speed you are considered still (m/s).
    private static let movingSpeed: Double = 1.5

    var body: some View {
        @Bindable var state = appState

        ZStack {
            mapLayer

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

            toastLayer
                .zIndex(20)
        }
        .background(Theme.obsidian)
        .animation(Theme.spring, value: appState.viewerSelection)
        .animation(Theme.spring, value: appState.toast)
        .fullScreenCover(isPresented: $state.isCameraPresented) {
            CameraStudioView()
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

    /// Your active photo, when you are still near it: it is drawn on your avatar.
    private var mergedOwnPin: PhotoPin? {
        guard let pin = appState.ownActivePin, let userLocation = appState.userLocation else { return nil }
        return GeoClustering.haversineDistance(from: pin.location, to: userLocation) <= Self.ownPinMergeDistance ? pin : nil
    }

    /// Clusters drawn as separate pins (your own single photo is merged into your avatar).
    private var visibleClusters: [PinCluster] {
        guard let merged = mergedOwnPin else { return appState.clusters }
        return appState.clusters.filter { cluster in
            !(cluster.pins.count == 1 && cluster.leadPin?.id == merged.id)
        }
    }

    /// Saved places drawn on the map: the one you are in is shown on your avatar instead.
    private var visiblePlaces: [SavedPlace] {
        guard let current = appState.currentPlace else { return appState.places }
        return appState.places.filter { $0.id != current.id }
    }

    private func openOwnPin(_ pin: PhotoPin) {
        HapticManager.shared.pinTap()
        let cluster = appState.clusters.first { $0.contains(pinID: pin.id) } ?? PinCluster(pins: [pin], center: pin.location)
        appState.openViewer(for: cluster, startingAt: pin.id)
    }

    // MARK: - Map

    private var mapLayer: some View {
        let skidSegments = SkidMarks.segments(trail: appState.trail, current: currentSpeed == nil ? nil : appState.userLocation)
        return Map(position: $cameraPosition, interactionModes: .all) {
            ForEach(skidSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Color(red: 0.06, green: 0.06, blue: 0.07).opacity(segment.opacity),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
            }

            ForEach(visiblePlaces) { place in
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

            ForEach(appState.visiblePublicPlaces) { place in
                Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
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

            ForEach(visibleClusters) { cluster in
                Annotation(appState.placeName(for: cluster) ?? "", coordinate: cluster.coordinate, anchor: .bottom) {
                    annotationView(for: cluster)
                }
                .annotationTitles(.hidden)
            }

            if let userLocation = appState.userLocation {
                let ownPin = mergedOwnPin
                Annotation("", coordinate: userLocation.coordinate, anchor: .center) {
                    MyLocationAnnotationView(
                        user: appState.currentUser,
                        ownPin: ownPin,
                        ownThumbnail: ownPin.flatMap { appState.thumbnail(for: $0) },
                        place: appState.currentPlace,
                        since: appState.presenceSince,
                        speed: currentSpeed,
                        onOpenPhoto: { pin in openOwnPin(pin) }
                    )
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(mapStyle)
        .mapControls {}
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
                    isHeroActive: !inactiveHeroIDs.contains(pin.id)
                )
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    // MARK: - HUD & dock

    private var overlayChrome: some View {
        VStack(spacing: 12) {
            topHUD
            Spacer(minLength: 0)
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
    }

    private var topHUD: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                brandPill
                statusPill
                friendsPill
                if let speed = currentSpeed {
                    speedPill(speed)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            Spacer(minLength: 8)
            viewsPill
                .padding(.top, 8)
            VStack(spacing: 10) {
                profileButton
                bellButton
            }
        }
    }

    private var brandPill: some View {
        HStack(spacing: 8) {
            AppLogoView(size: 24)
            Text(verbatim: "PinDrop")
                .font(Theme.rounded(.headline, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .glassCapsule()
    }

    /// "N profile views", like the counter next to the avatar.
    private var viewsPill: some View {
        Button {
            HapticManager.shared.tap()
            appState.isFriendsDrawerPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(Theme.neonPurple)
                Text("hud.profileViews \(appState.currentUser.viewCount)")
                    .contentTransition(.numericText())
            }
            .font(Theme.rounded(.footnote, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .glassCapsule()
            .fixedSize()
        }
        .buttonStyle(PressableButtonStyle())
        .animation(Theme.spring, value: appState.currentUser.viewCount)
    }

    private func speedPill(_ speed: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(Theme.warning)
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

    @ViewBuilder
    private var statusPill: some View {
        if let ownPin = appState.ownActivePin {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.emerald)
                    .frame(width: 8, height: 8)
                    .pulsing()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("hud.live \(LocaleFormatter.remaining(until: ownPin.expiresAt, from: context.date))")
                }
            }
            .font(Theme.rounded(.subheadline, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCapsule()
            .fixedSize()
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.neonPurple)
                Text("hud.locked")
            }
            .font(Theme.rounded(.subheadline, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCapsule()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var friendsPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(Theme.emerald)
            if appState.activeFriendsCount > 0 {
                Text("hud.friendsLive \(appState.activeFriendsCount)")
            } else {
                Text("hud.noFriendsLive")
            }
        }
        .font(Theme.rounded(.subheadline, weight: .semibold))
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCapsule()
        .fixedSize()
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
                .foregroundStyle(Theme.textPrimary)
                .symbolEffect(.bounce, value: unread)
                .frame(width: 48, height: 48)
                .glassCircle()
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
        .padding(.vertical, 10)
        .glassCapsule()
    }

    private func dockButton(systemImage: String, label: LocalizedStringKey, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white.opacity(0.06)))
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
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 80, height: 80)
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 66, height: 66)
                    .glow(Theme.electricViolet, radius: 16)
                Image(systemName: "camera.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.white)
            }
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
