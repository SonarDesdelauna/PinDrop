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
    /// Set when the shutter was held: a clip of up to 10 s (the image is its first frame).
    var videoURL: URL? = nil
}

/// Post-capture preview: choose a live pin (6 h, short caption) or a Geo-Capsule (24 h,
/// hint + secret message, opens only within 20 m), then drop it.
struct PostCaptureSheet: View {
    static let captionLimit = 40

    enum DropMode: Hashable {
        case live
        case capsule
        case relay
    }

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
    // Relay (Staffetta)
    @State private var relayTitle = ""
    @State private var relayEmoji = Relay.emojiPalette[0]
    @State private var relayPassTo: UserProfile?
    @State private var finishesRelay = false
    @FocusState private var isCaptionFocused: Bool
    @FocusState private var isHintFocused: Bool

    private var currentLimit: Int {
        mode == .capsule ? GeoCapsule.messageLimit : Self.captionLimit
    }

    /// The relay whose baton you hold, when the camera was opened to run your leg.
    private var runningRelay: Relay? {
        appState.relayRun
    }

    private var canDrop: Bool {
        guard shot.location != nil, !isPublishing else { return false }
        guard mode == .relay else { return true }
        if runningRelay != nil {
            return relayPassTo != nil || finishesRelay
        }
        return relayPassTo != nil && !relayTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if runningRelay == nil {
                    modeSelector
                }
                photo
                if mode == .capsule {
                    hintField
                    recipientPicker
                }
                if mode == .relay {
                    relaySection
                }
                captionField
                if mode == .capsule {
                    capsuleNote
                } else if mode == .relay {
                    relayNote
                } else {
                    privacyNote
                }
                if shot.location == nil {
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
            if runningRelay != nil {
                mode = .relay
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
                    .overlay {
                        if let video = shot.videoURL {
                            LoopingVideoView(url: video)
                        }
                    }
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
                    } else if mode == .relay {
                        Image(systemName: "figure.run")
                        Text("relay.duration")
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
            .overlay(alignment: .bottomLeading) {
                if !caption.isEmpty {
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
            modeButton(.relay, title: "post.mode.relay", icon: "figure.run")
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
                                : value == .relay ? AnyShapeStyle(RelayStyle.gradient) : AnyShapeStyle(Theme.accentGradient))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    // MARK: - Relay

    @ViewBuilder
    private var relaySection: some View {
        VStack(spacing: 12) {
            if let relay = runningRelay {
                HStack(spacing: 12) {
                    Text(verbatim: relay.emoji)
                        .font(.system(size: 26))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(RelayStyle.softGradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: relay.title)
                            .font(Theme.text(.headline, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("relay.post.leg \(relay.legs.count + 1)")
                            .font(Theme.text(.caption, weight: .semibold))
                            .foregroundStyle(RelayStyle.orange)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassCard(cornerRadius: Theme.Radius.control)
            } else {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(Relay.emojiPalette, id: \.self) { emoji in
                            Button {
                                HapticManager.shared.selection()
                                relayEmoji = emoji
                            } label: {
                                Text(verbatim: emoji)
                            }
                        }
                    } label: {
                        Text(verbatim: relayEmoji)
                            .font(.system(size: 24))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(RelayStyle.softGradient))
                    }
                    TextField("relay.post.title.placeholder", text: $relayTitle)
                        .font(Theme.text(.body, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .submitLabel(.done)
                    Text(verbatim: "\(relayTitle.count)/\(Relay.titleLimit)")
                        .font(Theme.rounded(.caption, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                .padding(10)
                .glassCard(cornerRadius: Theme.Radius.control)
                .onChange(of: relayTitle) { _, newValue in
                    if newValue.count > Relay.titleLimit {
                        relayTitle = String(newValue.prefix(Relay.titleLimit))
                    }
                }
            }
            relayPassPicker
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var relayPassPicker: some View {
        let candidates = appState.relayCandidates(for: runningRelay)
        return Menu {
            if runningRelay != nil {
                Button {
                    HapticManager.shared.selection()
                    relayPassTo = nil
                    finishesRelay = true
                } label: {
                    Label("relay.post.finish", systemImage: "flag.checkered")
                }
            }
            ForEach(candidates) { friend in
                Button {
                    HapticManager.shared.selection()
                    relayPassTo = friend
                    finishesRelay = false
                } label: {
                    Text(verbatim: friend.displayName)
                }
            }
        } label: {
            HStack(spacing: 10) {
                if let friend = relayPassTo {
                    AvatarBadge(user: friend, size: 30)
                } else {
                    Image(systemName: finishesRelay ? "flag.checkered" : "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(RelayStyle.orange)
                        .frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("relay.post.passTo")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                    Group {
                        if let friend = relayPassTo {
                            Text(verbatim: friend.displayName)
                        } else if finishesRelay {
                            Text("relay.post.finish")
                        } else if candidates.isEmpty {
                            Text("relay.post.noFriends")
                        } else {
                            Text("relay.post.choose")
                        }
                    }
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .glassCard(cornerRadius: Theme.Radius.control)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(RelayStyle.gradient, lineWidth: relayPassTo == nil && !finishesRelay ? 1.5 : 0)
            }
        }
    }

    private var relayNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "figure.run.circle.fill")
                .foregroundStyle(RelayStyle.orange)
            Text("relay.post.note \(LocaleFormatter.distance(meters: Relay.minimumLegDistance))")
                .font(Theme.text(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
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
            TextField(mode == .capsule ? LocalizedStringKey("post.capsule.message.placeholder") : LocalizedStringKey("post.caption.placeholder"), text: $caption, axis: mode == .capsule ? .vertical : .horizontal)
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
                    } else if mode == .relay {
                        Image(systemName: finishesRelay ? "flag.checkered" : "figure.run")
                        Text(finishesRelay ? "relay.post.finish" : "relay.post.pass")
                    } else {
                        Image(systemName: "mappin.and.ellipse")
                        Text("post.drop")
                    }
                }
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            .disabled(!canDrop)

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
        guard let location = shot.location, !isPublishing else { return }
        isCaptionFocused = false
        isHintFocused = false
        isPublishing = true
        errorMessage = nil
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .relay {
            let draft: RelayDraft
            if let relay = runningRelay {
                draft = .leg(relayID: relay.id, passTo: finishesRelay ? nil : relayPassTo?.id)
            } else if let friend = relayPassTo {
                draft = .start(title: relayTitle.trimmingCharacters(in: .whitespacesAndNewlines), emoji: relayEmoji, passTo: friend.id)
            } else {
                isPublishing = false
                return
            }
            let place = placeName
            Task {
                do {
                    try await appState.publishRelay(draft, processed: shot.processed, location: location, placeName: place, caption: trimmedCaption)
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
                        recipient: target,
                        video: shot.videoURL
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
                    caption: trimmedCaption,
                    video: shot.videoURL
                )
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
