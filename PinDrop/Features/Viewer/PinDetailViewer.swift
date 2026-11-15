import SwiftUI

/// Full-screen Stories-style viewer for a single pin or every POV of a Shared Hub.
struct PinDetailViewer: View {
    let selection: ViewerSelection
    let namespace: Namespace.ID

    @Environment(AppState.self) private var appState
    @State private var currentIndex = 0
    @State private var segmentProgress: Double = 0
    @State private var etaPin: PhotoPin?
    @State private var dragOffset: CGFloat = 0
    @State private var didSetInitialIndex = false

    private let storyDuration: Double = 6
    private let timerStep: Double = 0.05

    private var pins: [PhotoPin] {
        selection.pinIDs.compactMap { id in appState.pins.first { $0.id == id } }
    }

    private var currentPin: PhotoPin? {
        let list = pins
        guard !list.isEmpty else { return nil }
        return list[min(max(0, currentIndex), list.count - 1)]
    }

    var body: some View {
        ZStack {
            Theme.obsidian
                .opacity(1 - min(0.6, dragOffset / 500))
                .ignoresSafeArea()

            if let pin = currentPin {
                content(for: pin)
                    .offset(y: dragOffset)
                    .scaleEffect(1 - min(0.1, dragOffset / 2_000))
            }
        }
        .gesture(dismissGesture)
        .onAppear {
            guard !didSetInitialIndex else { return }
            didSetInitialIndex = true
            currentIndex = min(selection.startIndex, max(0, pins.count - 1))
        }
        .task(id: currentIndex) {
            await runStoryTimer()
        }
        .onChange(of: pins.isEmpty) { _, isEmpty in
            if isEmpty { close() }
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(for pin: PhotoPin) -> some View {
        let isLocked = appState.isLocked(pin)
        VStack(spacing: 14) {
            segmentsBar
            header(for: pin)
            photoCard(for: pin, isLocked: isLocked)
            if isLocked {
                lockedFooter(for: pin)
            } else {
                footer(for: pin)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            if let etaPin {
                ETAConfirmationBanner(pin: etaPin) {
                    withAnimation(Theme.spring) {
                        self.etaPin = nil
                    }
                }
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var segmentsBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(pins.enumerated()), id: \.element.id) { index, _ in
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.white)
                                .frame(width: proxy.size.width * fill(for: index))
                        }
                }
                .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(for index: Int) -> Double {
        if pins.count <= 1 { return 1 }
        if index < currentIndex { return 1 }
        if index == currentIndex { return min(1, max(0, segmentProgress)) }
        return 0
    }

    private func header(for pin: PhotoPin) -> some View {
        HStack(spacing: 10) {
            AvatarBadge(user: pin.author, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                if appState.isOwn(pin) {
                    Text("pin.you")
                        .font(Theme.text(.headline, weight: .bold))
                } else {
                    Text(verbatim: pin.author.displayName)
                        .font(Theme.text(.headline, weight: .bold))
                }
                HStack(spacing: 4) {
                    if let place = appState.placeName(for: pin) {
                        Text(verbatim: place)
                            .lineLimit(1)
                        Text(verbatim: "·")
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(verbatim: LocaleFormatter.relativeTimestamp(pin.createdAt, relativeTo: context.date))
                    }
                    .layoutPriority(1)
                }
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Button {
                HapticManager.shared.tap()
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleGlassButtonStyle(diameter: 40))
            .accessibilityLabel(Text("common.close"))
        }
    }

    private func photoCard(for pin: PhotoPin, isLocked: Bool) -> some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let source = appState.fullImage(for: pin),
                   let image = ImageCache.image(forKey: source.key, data: source.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Theme.surface
                }
            }
            .blur(radius: isLocked ? 18 : 0, opaque: true)
            .overlay {
                if isLocked {
                    lockedOverlay(for: pin)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if !isLocked, !pin.caption.isEmpty {
                    Text(verbatim: pin.caption)
                        .font(Theme.text(.title3, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 60)
                        .padding(.bottom, 18)
                        .background(Theme.photoScrim)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                expiryChip(for: pin)
                    .padding(12)
            }
            .overlay {
                if pins.count > 1 {
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { goToPrevious() }
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { goToNext() }
                    }
                }
            }
            .matchedGeometryEffect(id: HeroID.active(pin.id), in: namespace, isSource: true)
            .animation(Theme.spring, value: isLocked)
            .task(id: "\(pin.id.uuidString)-\(isLocked)") {
                await appState.loadFullImage(for: pin)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: pin.caption.isEmpty ? pin.author.displayName : pin.caption))
    }

    private func expiryChip(for pin: PhotoPin) -> some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ExpiryRing(progress: pin.remainingFraction(at: context.date), lineWidth: 2.5, isLive: appState.isOwn(pin))
            }
            .frame(width: 16, height: 16)
            Text("viewer.expires \(Text(pin.expiresAt, style: .relative))")
                .lineLimit(1)
        }
        .font(Theme.rounded(.caption, weight: .bold))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    private func lockedOverlay(for pin: PhotoPin) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.white)
                .glow(Theme.neonPurple, radius: 18)
            Text("viewer.locked.title")
                .font(Theme.text(.title3, weight: .bold))
                .foregroundStyle(Color.white)
            if let distance = appState.distanceText(to: pin.location) {
                Text("viewer.locked.distance \(distance)")
                    .font(Theme.rounded(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25))
    }

    private func footer(for pin: PhotoPin) -> some View {
        VStack(spacing: 12) {
            reactionsRow(for: pin)
            HStack(spacing: 10) {
                if !appState.isOwn(pin) {
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(Theme.spring) {
                            etaPin = pin
                        }
                    } label: {
                        Label("viewer.onMyWay", systemImage: "figure.walk")
                    }
                    .buttonStyle(PrimaryGradientButtonStyle())
                } else {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.emerald)
                            .frame(width: 8, height: 8)
                            .pulsing()
                        Text("viewer.ownLive")
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .glassCapsule()
                }
                if let distance = appState.distanceText(to: pin.location), !appState.isOwn(pin) {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                        Text(verbatim: distance)
                    }
                    .font(Theme.rounded(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .glassCapsule()
                    .fixedSize()
                }
            }
        }
    }

    private func reactionsRow(for pin: PhotoPin) -> some View {
        HStack(spacing: 8) {
            ForEach(PhotoPin.reactionPalette, id: \.self) { emoji in
                let count = pin.reactionCount(for: emoji)
                let isMine = pin.hasReaction(emoji, from: appState.currentUser.id)
                Button {
                    Task { await appState.toggleReaction(emoji, on: pin.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: emoji)
                            .font(.system(size: 20))
                        if count > 0 {
                            Text(count, format: .number)
                                .font(Theme.rounded(.caption, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(isMine ? Theme.electricViolet.opacity(0.35) : Color.white.opacity(0.07)))
                    .overlay(Capsule().strokeBorder(isMine ? Theme.neonPurple : Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
                .accessibilityLabel(Text(verbatim: emoji))
                .accessibilityValue(Text(count, format: .number))
            }
        }
    }

    private func lockedFooter(for pin: PhotoPin) -> some View {
        VStack(spacing: 10) {
            Text("viewer.locked.body")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                HapticManager.shared.tap()
                appState.presentCamera()
            } label: {
                Label("viewer.unlockCTA", systemImage: "camera.fill")
            }
            .buttonStyle(PrimaryGradientButtonStyle())
        }
    }

    // MARK: - Navigation

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard etaPin == nil else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 140 {
                    close()
                }
                withAnimation(Theme.spring) {
                    dragOffset = 0
                }
            }
    }

    private func goToNext() {
        guard etaPin == nil else { return }
        if currentIndex < pins.count - 1 {
            HapticManager.shared.selection()
            withAnimation(Theme.spring) {
                currentIndex += 1
            }
        } else {
            close()
        }
    }

    private func goToPrevious() {
        guard etaPin == nil else { return }
        if currentIndex > 0 {
            HapticManager.shared.selection()
            withAnimation(Theme.spring) {
                currentIndex -= 1
            }
        } else {
            segmentProgress = 0
        }
    }

    private func close() {
        etaPin = nil
        appState.closeViewer()
    }

    /// Auto-advances multi-POV stories every `storyDuration` seconds (paused during the ETA flow).
    private func runStoryTimer() async {
        segmentProgress = 0
        guard pins.count > 1 else {
            segmentProgress = 1
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int(timerStep * 1_000)))
            if Task.isCancelled { return }
            guard etaPin == nil else { continue }
            segmentProgress += timerStep / storyDuration
            if segmentProgress >= 1 {
                if currentIndex < pins.count - 1 {
                    withAnimation(Theme.spring) {
                        currentIndex += 1
                    }
                } else {
                    segmentProgress = 1
                }
                return
            }
        }
    }
}
