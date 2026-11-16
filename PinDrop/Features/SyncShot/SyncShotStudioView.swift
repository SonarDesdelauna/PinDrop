import AVFoundation
import SwiftUI
import UIKit

/// Sync Shot: you and a friend standing within 50 m shoot at the same instant from two angles.
/// The server hands out a shared fire time; both phones count down 3… 2… 1… and shoot at zero.
/// Each half is published as a pin of the same session and shown as one split-screen card.
struct SyncShotStudioView: View {
    let context: SyncShotContext

    private enum Phase: Equatable {
        case waitingForPartner
        case ready
        case countdown
        case capturing
        case uploading
        case waitingForPartnerShot
        case done
        case failed(String)
    }

    @Environment(AppState.self) private var appState
    @Environment(CameraService.self) private var camera
    @Environment(LocationService.self) private var locationService

    @State private var phase: Phase = .waitingForPartner
    @State private var fireDate: Date?
    @State private var countdownValue = 3
    @State private var ringProgress: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var myImage: UIImage?
    @State private var partnerImage: UIImage?
    @State private var myPinID: UUID?
    @State private var isArming = false
    @State private var pinchBaseZoom: CGFloat = 1

    /// Length of the shared countdown shown on screen (seconds).
    private static let countdownLength: Double = 3

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                topBar
                if phase == .done || phase == .waitingForPartnerShot || phase == .uploading {
                    resultCard
                } else {
                    viewfinder
                }
                Spacer(minLength: 0)
                bottomArea
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .animation(Theme.spring, value: phase)
        .task {
            await camera.start()
        }
        .task {
            await runSession()
        }
        .onDisappear {
            camera.stop()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                HapticManager.shared.tap()
                appState.closeSyncShot()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleGlassButtonStyle())
            .accessibilityLabel(Text("common.close"))

            Spacer(minLength: 8)

            partnerBadge

            Spacer(minLength: 8)

            Color.clear
                .frame(width: 44, height: 44)
        }
    }

    private var partnerBadge: some View {
        HStack(spacing: 8) {
            AvatarBadge(user: context.partner, size: 26)
            if phase == .waitingForPartner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.white)
                Text("sync.waiting \(context.partner.firstName)")
            } else {
                Circle()
                    .fill(Theme.emerald)
                    .frame(width: 8, height: 8)
                    .pulsing()
                Text("sync.connected \(context.partner.firstName)")
            }
        }
        .font(Theme.rounded(.footnote, weight: .heavy))
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .glassCapsule(tint: phase == .waitingForPartner ? nil : Theme.emerald.opacity(0.35))
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        ZStack {
            switch camera.status {
            case .unauthorized:
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Theme.accentGradient)
                    Text("camera.permission.title")
                        .font(Theme.text(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Button {
                        SystemSettings.openAppSettings()
                    } label: {
                        Text("common.openSettings")
                    }
                    .buttonStyle(PrimaryGradientButtonStyle(fullWidth: false))
                }
                .padding(24)
            case .failed(let message):
                Text(verbatim: message)
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(24)
            default:
                CameraPreviewLayer(session: camera.session) { camera.attachPreview($0) }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                camera.setZoom(pinchBaseZoom * value.magnification, animated: false)
                            }
                            .onEnded { _ in
                                pinchBaseZoom = camera.zoomFactor
                            }
                    )
            }

            if phase == .countdown {
                Text(countdownValue, format: .number)
                    .font(.system(size: 140, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
                    .shadow(color: Theme.electricViolet.opacity(0.8), radius: 24)
                    .contentTransition(.numericText(countsDown: true))
                    .id(countdownValue)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
            }

            if phase == .capturing {
                ProgressView()
                    .tint(Color.white)
                    .controlSize(.large)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .trim(from: 0, to: phase == .countdown ? ringProgress : 0)
                .stroke(
                    AngularGradient(colors: [Theme.electricViolet, Theme.emerald, Theme.neonPurple, Theme.electricViolet], center: .center),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .shadow(color: Theme.emerald.opacity(0.7), radius: 10)
                .padding(3)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                Text("sync.badge")
            }
            .font(Theme.text(.caption, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassCapsule()
            .padding(12)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: countdownValue)
    }

    // MARK: - Result

    private var resultCard: some View {
        SyncShotCardView(
            first: myImage,
            second: partnerImage,
            firstName: appState.currentUser.firstName,
            secondName: context.partner.firstName,
            isInteractive: phase == .done
        )
        .overlay(alignment: .top) {
            if phase != .done {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.white)
                    if phase == .uploading {
                        Text("sync.uploading")
                    } else {
                        Text("sync.waitingShot \(context.partner.firstName)")
                    }
                }
                .font(Theme.text(.caption, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassCapsule()
                .padding(.top, 12)
            }
        }
        .shadow(color: Theme.emerald.opacity(0.25), radius: 24, x: 0, y: 12)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    // MARK: - Bottom

    @ViewBuilder
    private var bottomArea: some View {
        switch phase {
        case .done:
            VStack(spacing: 10) {
                Button {
                    HapticManager.shared.tap()
                    let pinID = myPinID
                    appState.syncShotContext = nil
                    if let pinID {
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            appState.openPin(pinID)
                        }
                    }
                } label: {
                    Label("sync.viewOnMap", systemImage: "map.fill")
                }
                .buttonStyle(PrimaryGradientButtonStyle())
                Button {
                    HapticManager.shared.tap()
                    appState.syncShotContext = nil
                } label: {
                    Text("common.done")
                }
                .buttonStyle(GlassButtonStyle())
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
                .font(Theme.text(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                Button {
                    appState.closeSyncShot()
                } label: {
                    Text("common.close")
                }
                .buttonStyle(GlassButtonStyle())
            }
        default:
            VStack(spacing: 14) {
                shutterButton
                Text(hintText)
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hintText: LocalizedStringKey {
        switch phase {
        case .waitingForPartner: "sync.hint.waiting \(context.partner.firstName)"
        case .countdown: "sync.hint.countdown"
        default: "sync.hint.ready \(context.partner.firstName)"
        }
    }

    private var shutterButton: some View {
        let isEnabled = phase == .ready && camera.status == .running && !isArming
        return Button {
            arm()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [Theme.electricViolet, Theme.emerald, Theme.electricViolet], center: .center),
                        lineWidth: 5
                    )
                    .frame(width: 90, height: 90)
                Circle()
                    .fill(LinearGradient(colors: [Theme.electricViolet, Theme.emerald], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .scaleEffect(phase == .countdown ? 0.84 : 1)
                    .glow(Theme.emerald, radius: 14)
                if isArming || phase == .waitingForPartner {
                    ProgressView()
                        .tint(Color.white)
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
        .disabled(!isEnabled)
        .opacity(isEnabled || phase == .countdown ? 1 : 0.55)
        .accessibilityLabel(Text("sync.shutter"))
    }

    // MARK: - Session

    private func arm() {
        guard phase == .ready, !isArming else { return }
        HapticManager.shared.tap()
        if context.isDemo {
            startCountdown(fireAt: Date.now.addingTimeInterval(Self.countdownLength + 0.2))
            return
        }
        isArming = true
        Task {
            do {
                try await appState.dataService.syncArm(context.id)
            } catch {
                HapticManager.shared.error()
                phase = .failed(error.localizedDescription)
            }
            isArming = false
        }
    }

    /// Follows the session on the server: partner joining, countdown start, cancellation.
    private func runSession() async {
        if context.isDemo {
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            HapticManager.shared.success()
            phase = .ready
            return
        }
        phase = context.isInitiator ? .waitingForPartner : .ready
        let startedAt = Date.now
        while !Task.isCancelled {
            if phase == .countdown || phase == .capturing || phase == .uploading || phase == .waitingForPartnerShot || phase == .done {
                return
            }
            let sentAt = Date.now
            if let poll = try? await appState.dataService.syncPoll(context.id) {
                let receivedAt = Date.now
                let localMidpoint = sentAt.addingTimeInterval(receivedAt.timeIntervalSince(sentAt) / 2)
                let clockOffset = poll.serverNow.timeIntervalSince(localMidpoint)
                switch poll.status {
                case "ready":
                    if phase == .waitingForPartner {
                        HapticManager.shared.success()
                        phase = .ready
                    }
                case "armed":
                    if let fireAt = poll.fireAt {
                        startCountdown(fireAt: fireAt.addingTimeInterval(-clockOffset))
                        return
                    }
                case "cancelled":
                    HapticManager.shared.warning()
                    phase = .failed(String(localized: "sync.cancelled \(context.partner.firstName)"))
                    return
                default:
                    if Date.now.timeIntervalSince(startedAt) > 120 {
                        phase = .failed(String(localized: "sync.timeout \(context.partner.firstName)"))
                        let dataService = appState.dataService
                        let sessionID = context.id
                        Task {
                            try? await dataService.syncCancel(sessionID)
                        }
                        return
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(phase == .ready ? 300 : 700))
        }
    }

    private func startCountdown(fireAt: Date) {
        guard phase != .countdown else { return }
        fireDate = fireAt
        phase = .countdown
        HapticManager.shared.prepare()
        Task {
            var lastTick = 0
            while !Task.isCancelled {
                let remaining = fireAt.timeIntervalSinceNow
                if remaining <= 0 { break }
                let value = min(3, max(1, Int(remaining.rounded(.up))))
                if value != lastTick {
                    lastTick = value
                    countdownValue = value
                    HapticManager.shared.countdownTick(value)
                }
                ringProgress = min(1, max(0, 1 - remaining / Self.countdownLength))
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            ringProgress = 1
            await fire()
        }
    }

    private func fire() async {
        phase = .capturing
        HapticManager.shared.syncFire()
        withAnimation(.easeOut(duration: 0.08)) {
            flashOpacity = 0.85
        }
        let camera = self.camera
        let locationService = self.locationService
        async let photoData = camera.capturePhoto()
        async let locationFix = locationService.currentLocation(maximumAge: 30, timeout: 1.5)
        do {
            let raw = try await photoData
            let fix = await locationFix
            withAnimation(.easeIn(duration: 0.3)) {
                flashOpacity = 0
            }
            let processed = await Task.detached(priority: .userInitiated) {
                ImageCompressor.process(raw)
            }.value
            guard let processed else { throw CameraError.captureFailed }
            myImage = UIImage(data: processed.fullData)
            let location = appState.simulatedLocation ?? fix ?? appState.userLocation
            guard let location else {
                phase = .failed(String(localized: "sync.noLocation"))
                return
            }
            phase = .uploading
            if context.isDemo {
                await finishDemo(processed: processed, location: location)
            } else {
                await publishHalf(processed: processed, location: location)
            }
        } catch {
            withAnimation(.easeIn(duration: 0.3)) {
                flashOpacity = 0
            }
            HapticManager.shared.error()
            phase = .failed(error.localizedDescription)
        }
    }

    private func finishDemo(processed: ProcessedImage, location: GeoPoint) async {
        let name = context.partner.firstName
        let partner = await Task.detached(priority: .userInitiated) {
            MockDataService.partnerShot(from: processed, partnerName: name)
        }.value
        guard let partner else {
            phase = .failed(String(localized: "toast.error.title"))
            return
        }
        phase = .waitingForPartnerShot
        try? await Task.sleep(for: .milliseconds(900))
        partnerImage = UIImage(data: partner.fullData)
        let placeName = await locationService.placeName(for: location)
        myPinID = appState.addDemoSyncShot(mine: processed, partnerImage: partner, partner: context.partner, location: location, placeName: placeName)?.id
        HapticManager.shared.success()
        phase = .done
    }

    private func publishHalf(processed: ProcessedImage, location: GeoPoint) async {
        do {
            let pin = try await appState.publish(
                processed: processed,
                location: location,
                placeName: nil,
                caption: "",
                syncSessionID: context.id
            )
            myPinID = pin.id
        } catch {
            HapticManager.shared.error()
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .waitingForPartnerShot
        for _ in 0..<45 {
            guard !Task.isCancelled else { return }
            if let pins = try? await appState.dataService.fetchSyncPins(session: context.id),
               let partnerPin = pins.first(where: { $0.author.id != appState.currentUser.id }) {
                appState.ingest(pins)
                await appState.loadFullImage(for: partnerPin)
                if let source = appState.fullImage(for: partnerPin) {
                    partnerImage = UIImage(data: source.data)
                }
                HapticManager.shared.success()
                phase = .done
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        phase = .done
    }
}

// MARK: - Floating trigger

/// Glowing "Sync Shot ⚡" pill shown on the map when a friend is within 50 m.
struct SyncShotPill: View {
    let candidates: [UserProfile]
    let onSelect: (UserProfile) -> Void

    @State private var rotation: Double = 0

    var body: some View {
        Group {
            if candidates.count == 1, let friend = candidates.first {
                Button {
                    onSelect(friend)
                } label: {
                    label(names: friend.firstName, avatars: [friend])
                }
            } else {
                Menu {
                    ForEach(candidates) { friend in
                        Button {
                            onSelect(friend)
                        } label: {
                            Text(verbatim: friend.displayName)
                        }
                    }
                } label: {
                    label(names: candidates.map(\.firstName).joined(separator: ", "), avatars: candidates)
                }
            }
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }

    private func label(names: String, avatars: [UserProfile]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -10) {
                ForEach(avatars.prefix(3)) { friend in
                    AvatarBadge(user: friend, size: 30)
                        .overlay(Circle().strokeBorder(Theme.obsidian, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("sync.pill.title")
                    .font(Theme.rounded(.subheadline, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text("sync.pill.subtitle \(names)")
                    .font(Theme.text(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Image(systemName: "bolt.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.emeraldLight)
                .symbolEffect(.pulse)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .glassCapsule(interactive: true)
        .overlay {
            Capsule()
                .strokeBorder(
                    AngularGradient(
                        colors: [Theme.electricViolet, Theme.emerald, Theme.neonPurple, Theme.emerald, Theme.electricViolet],
                        center: .center,
                        angle: .degrees(rotation)
                    ),
                    lineWidth: 2
                )
        }
        .shadow(color: Theme.emerald.opacity(0.45), radius: 14)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Incoming invitation

/// "Marco invites you to a Sync Shot ⚡" with Accept / Decline.
struct SyncInviteBanner: View {
    let invite: IncomingSyncInvite
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AvatarBadge(user: invite.from, size: 44)
                .padding(2)
                .overlay(Circle().strokeBorder(Theme.emerald, lineWidth: 2))
            VStack(alignment: .leading, spacing: 3) {
                Text("sync.invite.title \(invite.from.firstName)")
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("sync.invite.subtitle")
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onAccept) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(LinearGradient(colors: [Theme.electricViolet, Theme.emerald], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("sync.invite.accept"))
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("sync.invite.decline"))
        }
        .padding(12)
        .glassCard(cornerRadius: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.electricViolet, Theme.emerald], startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
        }
    }
}
