import MapKit
import SwiftUI

/// Dark social map with floating HUD, bottom dock, hub clustering and the Stories viewer overlay.
struct MainMapView: View {
    @Environment(AppState.self) private var appState
    @Namespace private var heroNamespace
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnUser = false

    var body: some View {
        @Bindable var state = appState

        ZStack {
            mapLayer

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
        .sheet(isPresented: $state.isFriendsDrawerPresented) {
            FriendsDrawerView()
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
        .onAppear {
            if let location = appState.userLocation, !hasCenteredOnUser {
                hasCenteredOnUser = true
                cameraPosition = .region(region(around: location, spanMeters: 2_600))
            }
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            ForEach(appState.clusters) { cluster in
                Annotation(appState.placeName(for: cluster) ?? "", coordinate: cluster.coordinate, anchor: .bottom) {
                    annotationView(for: cluster)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapCompass()
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
    }

    private var topHUD: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                brandPill
                Spacer(minLength: 8)
                profileButton
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusPill
                    friendsPill
                }
                VStack(alignment: .leading, spacing: 8) {
                    statusPill
                    friendsPill
                }
            }
        }
    }

    private var brandPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
            Text(verbatim: "PinDrop")
                .font(Theme.rounded(.headline, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCapsule()
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
            Spacer(minLength: 12)
            shutterButton
            Spacer(minLength: 12)
            dockButton(systemImage: "person.2.fill", label: "dock.friends", badge: appState.activeFriendsCount) {
                HapticManager.shared.tap()
                appState.isFriendsDrawerPresented = true
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .glassCapsule()
    }

    private func dockButton(systemImage: String, label: LocalizedStringKey, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 52, height: 52)
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
        let target = appState.ownActivePin?.location ?? appState.userLocation
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
