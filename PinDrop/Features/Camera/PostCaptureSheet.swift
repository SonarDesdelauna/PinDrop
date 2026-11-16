import SwiftUI
import UIKit

/// A freshly captured live photo, waiting to be dropped.
struct CapturedShot: Identifiable {
    let id = UUID()
    let previewImage: UIImage
    let processed: ProcessedImage
    /// The GPS fix taken at the instant of the shot. `nil` when location access is denied.
    let location: GeoPoint?
    let capturedAt: Date
}

/// Post-capture preview: choose a live pin (6 h, short caption) or a Geo-Capsule (24 h,
/// hint + secret message, opens only within 20 m), then drop it.
struct PostCaptureSheet: View {
    static let captionLimit = 40

    enum DropMode: Hashable {
        case live
        case capsule
    }

    /// Where a live photo goes: a 6 h pin on the map, a 24 h story, or both.
    enum Destination: Hashable {
        case pin
        case story
        case both

        var includesPin: Bool { self != .story }
        var includesStory: Bool { self != .pin }
    }

    static let storyTextLimit = 80

    let shot: CapturedShot
    let onRetake: () -> Void
    let onDropped: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(LocationService.self) private var locationService

    @State private var caption = ""
    @State private var placeName: String?
    @State private var isResolvingPlace = true
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var mode: DropMode = .live
    @State private var hint = ""
    @State private var recipient: UserProfile?
    @State private var destination: Destination = .pin
    @State private var overlayY: Double = 0.75
    @State private var dragStartY: Double?
    @FocusState private var isCaptionFocused: Bool
    @FocusState private var isHintFocused: Bool

    private var currentLimit: Int {
        if mode == .capsule { return GeoCapsule.messageLimit }
        return destination == .story ? Self.storyTextLimit : Self.captionLimit
    }

    private var isStoryShot: Bool {
        mode == .live && destination.includesStory
    }

    /// A story alone can be posted without a GPS fix.
    private var needsLocation: Bool {
        mode == .capsule || destination.includesPin
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                modeSelector
                if mode == .live {
                    destinationSelector
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                photo
                if mode == .capsule {
                    hintField
                    recipientPicker
                }
                captionField
                if mode == .capsule {
                    capsuleNote
                } else {
                    privacyNote
                }
                if shot.location == nil, needsLocation {
                    locationWarning
                }
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(Theme.text(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.obsidian.ignoresSafeArea())
        .task {
            await resolvePlace()
        }
        .onAppear {
            if appState.social.prefersStoryCapture {
                destination = .story
                appState.social.prefersStoryCapture = false
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            Text("post.title")
                .font(Theme.text(.title2, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("post.subtitle")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var photo: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                Image(uiImage: shot.previewImage)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.photo, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.photo, style: .continuous)
                    .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                placePill
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if mode == .capsule {
                        Image(systemName: "lock.fill")
                        Text("post.capsule.duration")
                    } else if destination == .story {
                        Image(systemName: "circle.dashed")
                        Text("story.duration")
                    } else if destination == .both {
                        Image(systemName: "timer")
                        Text("story.duration.both")
                    } else {
                        Image(systemName: "timer")
                        Text("camera.sixHours")
                    }
                }
                .font(Theme.rounded(.caption, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassCapsule()
                .padding(12)
            }
            .overlay {
                if isStoryShot {
                    storyTextOverlay
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !caption.isEmpty, !isStoryShot {
                    Text(verbatim: caption)
                        .font(Theme.text(.headline, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.6), radius: 6)
                        .padding(16)
                        .transition(.opacity)
                }
            }
            .overlay {
                if mode == .capsule {
                    RoundedRectangle(cornerRadius: Theme.Radius.photo, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color(hex: 0xF59E0B), Color(hex: 0xA855F7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2
                        )
                }
            }
            .shadow(color: (mode == .capsule ? Color(hex: 0xF59E0B) : Theme.electricViolet).opacity(0.25), radius: 24, x: 0, y: 12)
            .animation(Theme.spring, value: caption.isEmpty)
            .animation(Theme.spring, value: mode)
    }

    /// "Pin Live (6h)" vs "Geo-Capsule 🔒".
    private var modeSelector: some View {
        HStack(spacing: 4) {
            modeButton(.live, title: "post.mode.live", icon: "timer")
            modeButton(.capsule, title: "post.mode.capsule", icon: "lock.fill")
        }
        .padding(4)
        .glassCapsule()
    }

    private func modeButton(_ value: DropMode, title: LocalizedStringKey, icon: String) -> some View {
        let isSelected = mode == value
        return Button {
            guard mode != value else { return }
            HapticManager.shared.selection()
            withAnimation(Theme.spring) {
                mode = value
                if caption.count > currentLimit {
                    caption = String(caption.prefix(currentLimit))
                }
            }
        } label: {
            Label(title, systemImage: icon)
                .font(Theme.rounded(.subheadline, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(value == .capsule
                                ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xF59E0B), Color(hex: 0xA855F7)], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Theme.accentGradient))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "Pin 6h" / "Story 24h" / "Both".
    private var destinationSelector: some View {
        HStack(spacing: 4) {
            destinationButton(.pin, title: "story.destination.pin", icon: "mappin.and.ellipse")
            destinationButton(.story, title: "story.destination.story", icon: "circle.dashed")
            destinationButton(.both, title: "story.destination.both", icon: "square.stack.fill")
        }
        .padding(4)
        .glassCapsule()
    }

    private func destinationButton(_ value: Destination, title: LocalizedStringKey, icon: String) -> some View {
        let isSelected = destination == value
        return Button {
            guard destination != value else { return }
            HapticManager.shared.selection()
            withAnimation(Theme.spring) {
                destination = value
                if caption.count > currentLimit {
                    caption = String(caption.prefix(currentLimit))
                }
            }
        } label: {
            Label(title, systemImage: icon)
                .font(Theme.rounded(.footnote, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background {
                    if isSelected {
                        Capsule().fill(value == .pin ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(StoryRingStyle.linear))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The story text pill: drag it up or down on the photo.
    private var storyTextOverlay: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            VStack(spacing: 8) {
                StoryTextPill(text: caption.isEmpty ? String(localized: "story.text.placeholder") : caption, isPlaceholder: caption.isEmpty)
                if let placeName {
                    StoryLocationTag(name: placeName)
                }
            }
            .frame(maxWidth: max(proxy.size.width - 32, 1))
            .position(x: proxy.size.width / 2, y: height * overlayY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartY == nil { dragStartY = overlayY }
                        let start = dragStartY ?? overlayY
                        overlayY = min(0.88, max(0.12, start + value.translation.height / max(height, 1)))
                    }
                    .onEnded { _ in
                        dragStartY = nil
                        HapticManager.shared.selection()
                    }
            )
            .onTapGesture {
                isCaptionFocused = true
            }
        }
        .transition(.opacity)
    }

    private var hintField: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Color(hex: 0xF59E0B))
            TextField("post.capsule.hint.placeholder", text: $hint, axis: .vertical)
                .font(Theme.text(.body))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .focused($isHintFocused)
                .submitLabel(.next)
            Text(verbatim: "\(hint.count)/\(GeoCapsule.hintLimit)")
                .font(Theme.rounded(.caption, weight: .bold))
                .foregroundStyle(hint.count >= GeoCapsule.hintLimit ? Theme.warning : Theme.textSecondary)
                .monospacedDigit()
        }
        .padding(14)
        .glassCard(cornerRadius: Theme.Radius.control)
        .onChange(of: hint) { _, newValue in
            if newValue.count > GeoCapsule.hintLimit {
                hint = String(newValue.prefix(GeoCapsule.hintLimit))
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var recipientPicker: some View {
        Menu {
            Button {
                HapticManager.shared.selection()
                recipient = nil
            } label: {
                Label("post.capsule.recipient.everyone", systemImage: "person.3.fill")
            }
            ForEach(appState.friends) { friend in
                Button {
                    HapticManager.shared.selection()
                    recipient = friend
                } label: {
                    Text(verbatim: friend.displayName)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: recipient == nil ? "person.3.fill" : "person.fill")
                    .foregroundStyle(Theme.neonPurple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("post.capsule.recipient.title")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                    if let recipient {
                        Text(verbatim: recipient.displayName)
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("post.capsule.recipient.everyone")
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .glassCard(cornerRadius: Theme.Radius.control)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var capsuleNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "location.circle.fill")
                .foregroundStyle(Color(hex: 0xF59E0B))
            Text("post.capsule.note \(LocaleFormatter.distance(meters: GeoCapsule.unlockRadius))")
                .font(Theme.text(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var placePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(Theme.emerald)
            if isResolvingPlace {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.white)
            } else if let placeName {
                Text(verbatim: placeName)
                    .lineLimit(1)
            } else if shot.location != nil {
                Text("post.place.unknown")
            } else {
                Text("post.place.missing")
            }
        }
        .font(Theme.text(.caption, weight: .semibold))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    private var captionField: some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .capsule ? "envelope.fill" : "text.bubble.fill")
                .foregroundStyle(Theme.neonPurple)
            TextField(mode == .capsule ? LocalizedStringKey("post.capsule.message.placeholder") : (isStoryShot ? LocalizedStringKey("story.text.field") : LocalizedStringKey("post.caption.placeholder")), text: $caption, axis: mode == .capsule ? .vertical : .horizontal)
                .font(Theme.text(.body))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...4)
                .focused($isCaptionFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.sentences)
                .onSubmit { isCaptionFocused = false }
            Text(verbatim: "\(caption.count)/\(currentLimit)")
                .font(Theme.rounded(.caption, weight: .bold))
                .foregroundStyle(caption.count >= currentLimit ? Theme.warning : Theme.textSecondary)
                .monospacedDigit()
        }
        .padding(14)
        .glassCard(cornerRadius: Theme.Radius.control)
        .onChange(of: caption) { _, newValue in
            if newValue.count > currentLimit {
                caption = String(newValue.prefix(currentLimit))
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Theme.emerald)
            Text("post.privacy")
                .font(Theme.text(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var locationWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "location.slash.fill")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("post.location.title")
                        .font(Theme.text(.subheadline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("post.location.body")
                        .font(Theme.text(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                SystemSettings.openAppSettings()
            } label: {
                Text("common.openSettings")
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(14)
        .glassCard(cornerRadius: Theme.Radius.control)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                drop()
            } label: {
                HStack(spacing: 8) {
                    if isPublishing {
                        ProgressView()
                            .tint(Color.white)
                        Text("post.dropping")
                    } else if mode == .capsule {
                        Image(systemName: "shippingbox.fill")
                        Text("post.capsule.drop")
                    } else if destination == .story {
                        Image(systemName: "circle.dashed")
                        Text("story.publish")
                    } else if destination == .both {
                        Image(systemName: "square.stack.fill")
                        Text("story.publish.both")
                    } else {
                        Image(systemName: "mappin.and.ellipse")
                        Text("post.drop")
                    }
                }
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            .disabled((needsLocation && shot.location == nil) || isPublishing)

            Button {
                HapticManager.shared.tap()
                onRetake()
            } label: {
                Text("post.retake")
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(isPublishing)
        }
    }

    // MARK: - Logic

    private func resolvePlace() async {
        guard let location = shot.location else {
            isResolvingPlace = false
            return
        }
        placeName = await locationService.placeName(for: location)
        isResolvingPlace = false
    }

    private func drop() {
        guard !isPublishing else { return }
        if mode == .live, destination == .story {
            publishStoryOnly()
            return
        }
        guard let location = shot.location else { return }
        isCaptionFocused = false
        isHintFocused = false
        isPublishing = true
        errorMessage = nil
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .capsule {
            let hintText = hint
            let target = recipient
            Task {
                do {
                    try await appState.hideCapsule(
                        processed: shot.processed,
                        location: location,
                        hint: hintText,
                        message: trimmedCaption,
                        recipient: target
                    )
                    isPublishing = false
                    onDropped()
                } catch {
                    HapticManager.shared.error()
                    errorMessage = error.localizedDescription
                    isPublishing = false
                }
            }
            return
        }
        Task {
            do {
                try await appState.publish(
                    processed: shot.processed,
                    location: location,
                    placeName: placeName,
                    caption: trimmedCaption
                )
                if destination == .both {
                    try? await appState.social.publishStory(
                        photo: shot.processed.fullData,
                        overlayText: trimmedCaption,
                        overlayY: overlayY,
                        locationTag: placeName
                    )
                }
                isPublishing = false
                onDropped()
            } catch {
                HapticManager.shared.error()
                errorMessage = error.localizedDescription
                isPublishing = false
            }
        }
    }

    private func publishStoryOnly() {
        isCaptionFocused = false
        isPublishing = true
        errorMessage = nil
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await appState.social.publishStory(
                    photo: shot.processed.fullData,
                    overlayText: text,
                    overlayY: overlayY,
                    locationTag: placeName
                )
                HapticManager.shared.success()
                appState.showToast(.success, title: String(localized: "story.published.title"), subtitle: String(localized: "story.published.subtitle"))
                isPublishing = false
                onDropped()
            } catch {
                HapticManager.shared.error()
                errorMessage = error.localizedDescription
                isPublishing = false
            }
        }
    }
}
