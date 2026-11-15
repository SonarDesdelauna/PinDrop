import SwiftUI

// MARK: - Map annotations (no environment access: Map annotation content does not inherit it)

/// The user's own position on the map: avatar with your live photo around it, the saved
/// place you are in as a small badge, and how long you've been there (or your speed).
struct MyLocationAnnotationView: View {
    let user: UserProfile
    let ownPin: PhotoPin?
    /// Other live photos of yours taken here (shown as `+N`).
    let extraPhotoCount: Int
    let ownThumbnail: PinImage?
    let place: SavedPlace?
    let since: Date?
    let speed: Double?
    /// Friends standing with you, drawn side by side next to your avatar (like Bump).
    var companions: [UserProfile] = []
    var onlineIDs: Set<UUID> = []
    let onOpenPhoto: (PhotoPin) -> Void

    @State private var isPulsing = false

    private let avatarSize: CGFloat = 34
    private var ringSize: CGFloat { avatarSize + 14 }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Theme.emerald.opacity(0.25))
                    .frame(width: 56, height: 56)
                    .scaleEffect(isPulsing ? 1.25 : 0.85)
                    .opacity(isPulsing ? 0 : 0.9)

                if let ownPin {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ExpiryRing(progress: ownPin.remainingFraction(at: context.date), lineWidth: 3.5, isLive: true)
                    }
                    .frame(width: ringSize, height: ringSize)
                }

                AvatarBadge(user: user, size: avatarSize)
                    .padding(3)
                    .background(Circle().fill(Color.white))
                    .shadow(color: Theme.emerald.opacity(0.6), radius: 10)
            }
            .frame(width: 56, height: 56)
            .overlay(alignment: .trailing) {
                if !companions.isEmpty {
                    HStack(spacing: -7) {
                        ForEach(companions.prefix(4)) { friend in
                            AvatarBadge(user: friend, size: 28)
                                .padding(2)
                                .background(Circle().fill(onlineIDs.contains(friend.id) ? Theme.emerald : Color.white))
                        }
                        if companions.count > 4 {
                            Text(verbatim: "+\(companions.count - 4)")
                                .font(Theme.roundedFixed(10, weight: .heavy))
                                .foregroundStyle(Color.white)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.accentGradient))
                        }
                    }
                    .shadow(color: Color.black.opacity(0.4), radius: 5)
                    .fixedSize()
                    .alignmentGuide(HorizontalAlignment.trailing) { dimensions in dimensions[.leading] + 6 }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let ownPin {
                    Button {
                        onOpenPhoto(ownPin)
                    } label: {
                        PinThumbnail(pin: ownPin, image: ownThumbnail, size: 26, isLocked: false)
                            .shadow(color: Color.black.opacity(0.45), radius: 5, x: 0, y: 3)
                            .overlay(alignment: .topTrailing) {
                                if extraPhotoCount > 0 {
                                    Text(verbatim: "+\(extraPhotoCount)")
                                        .font(Theme.roundedFixed(9, weight: .heavy))
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Theme.accentGradient))
                                        .offset(x: 6, y: -4)
                                }
                            }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .offset(x: 10, y: -6)
                    .accessibilityLabel(Text("presence.yourPhoto"))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let place {
                    Text(verbatim: place.emoji)
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.surface))
                        .overlay {
                            Circle().strokeBorder(Theme.emeraldGradient, lineWidth: 2)
                        }
                        .shadow(color: Color.black.opacity(0.4), radius: 4, x: 0, y: 2)
                        .offset(x: 2, y: 0)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            label
        }
        .animation(Theme.spring, value: place?.id)
        .animation(Theme.spring, value: ownPin?.id)
        .animation(Theme.spring, value: speed == nil)
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("presence.you"))
    }

    @ViewBuilder
    private var label: some View {
        if let speed {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(Theme.warning)
                Text(verbatim: LocaleFormatter.speed(metersPerSecond: speed))
                    .monospacedDigit()
            }
            .font(Theme.roundedFixed(11, weight: .heavy))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassCapsule()
            .fixedSize()
        } else if let since {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let duration = LocaleFormatter.dwell(since: since, now: context.date)
                HStack(spacing: 4) {
                    if let place {
                        Text("presence.atPlace \(place.name) \(duration)")
                    } else {
                        Image(systemName: "clock.fill")
                            .foregroundStyle(Theme.emerald)
                        Text("presence.here \(duration)")
                    }
                }
                .font(Theme.roundedFixed(11, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .glassCapsule()
                .fixedSize()
            }
        }
    }
}

/// Someone else's public place on the map, with the owner's avatar.
struct PublicPlaceAnnotationView: View {
    let place: PublicPlace

    private var owner: UserProfile {
        UserProfile(
            id: place.ownerID,
            username: place.ownerUsername,
            displayName: place.ownerDisplayName,
            bio: "",
            statusEmoji: "",
            avatarColorHex: place.ownerAvatarColor,
            avatarPath: place.ownerAvatarPath,
            inviteCode: "",
            isSetup: true
        )
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: place.emoji)
                .font(.system(size: 19))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.surface.opacity(0.85)))
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
                .overlay(alignment: .bottomTrailing) {
                    AvatarBadge(user: owner, size: 18)
                        .offset(x: 5, y: 3)
                }
            Text(verbatim: place.name)
                .font(Theme.roundedFixed(9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .glassCapsule()
                .fixedSize()
        }
        .opacity(0.92)
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("publicPlace.a11y \(place.name) \(place.ownerDisplayName)"))
        .accessibilityAddTraits(.isButton)
    }
}

/// A saved place on the map with its visit counter.
struct PlaceAnnotationView: View {
    let place: SavedPlace
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: place.emoji)
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.surface.opacity(0.92)))
                .overlay {
                    Circle().strokeBorder(isCurrent ? AnyShapeStyle(Theme.emeraldGradient) : AnyShapeStyle(Theme.glassBorderGradient), lineWidth: isCurrent ? 2.5 : 1.2)
                }
                .overlay(alignment: .topTrailing) {
                    Text(verbatim: "×\(place.visitCount)")
                        .font(Theme.roundedFixed(10, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentGradient))
                        .offset(x: 8, y: -4)
                }
            Text(verbatim: place.name)
                .font(Theme.roundedFixed(10, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassCapsule()
                .fixedSize()
        }
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: place.name))
        .accessibilityValue(Text("places.visits \(place.visitCount)"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Places list

/// "My places": every saved place with how many times you've been there.
struct PlacesView: View {
    let onSelect: (SavedPlace) -> Void
    let onAdd: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editingPlace: SavedPlace?
    @State private var placePendingDeletion: SavedPlace?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    presenceCard
                    if appState.places.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(appState.places.enumerated()), id: \.element.id) { index, place in
                                placeRow(place)
                                if index < appState.places.count - 1 {
                                    Divider()
                                        .overlay(Color.white.opacity(0.06))
                                        .padding(.leading, 70)
                                }
                            }
                        }
                        .glassCard()
                        Text("places.hint")
                            .font(Theme.text(.caption2))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    Button {
                        onAdd()
                    } label: {
                        Label("places.add", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryGradientButtonStyle())
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await appState.reloadPlaces()
            }
            .navigationTitle(Text("places.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("common.done")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await appState.reloadPlaces()
        }
        .sheet(item: $editingPlace) { place in
            PlaceEditorView(mode: .edit(place), userLocation: nil, mapCenter: nil)
                .presentationDetents([.large])
        }
        .confirmationDialog(
            Text("places.delete.title"),
            isPresented: Binding(
                get: { placePendingDeletion != nil },
                set: { if !$0 { placePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: placePendingDeletion
        ) { place in
            Button(role: .destructive) {
                Task { await appState.deletePlace(place) }
            } label: {
                Text("places.delete.confirm \(place.name)")
            }
            Button(role: .cancel) {} label: {
                Text("common.cancel")
            }
        } message: { _ in
            Text("places.delete.message")
        }
    }

    @ViewBuilder
    private var presenceCard: some View {
        if let since = appState.presenceSince {
            HStack(spacing: 12) {
                Text(verbatim: appState.currentPlace?.emoji ?? "📍")
                    .font(.system(size: 26))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.emerald.opacity(0.18)))
                VStack(alignment: .leading, spacing: 3) {
                    if let place = appState.currentPlace {
                        Text(verbatim: place.name)
                            .font(Theme.text(.headline, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("presence.unsavedSpot")
                            .font(Theme.text(.headline, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("presence.here \(LocaleFormatter.dwell(since: since, now: context.date))")
                    }
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.emerald)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .glassCard()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            Text("places.empty.title")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("places.empty.body")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard()
    }

    private func placeRow(_ place: SavedPlace) -> some View {
        let isCurrent = appState.currentPlace?.id == place.id
        return Button {
            HapticManager.shared.tap()
            onSelect(place)
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: place.emoji)
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay {
                        if isCurrent {
                            Circle().strokeBorder(Theme.emeraldGradient, lineWidth: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: place.name)
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: place.isPublic ? "globe.europe.africa.fill" : "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(place.isPublic ? Theme.emerald : Theme.textSecondary)
                            .accessibilityLabel(place.isPublic ? Text("places.public") : Text("places.private"))
                    }
                    Group {
                        if isCurrent {
                            Text("places.youAreHere")
                                .foregroundStyle(Theme.emerald)
                        } else if let last = place.lastVisitAt {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text("places.lastVisit \(LocaleFormatter.relativeTimestamp(last, relativeTo: context.date))")
                            }
                            .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("places.neverVisited")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .font(Theme.text(.caption))
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("places.visits \(place.visitCount)")
                    .font(Theme.rounded(.subheadline, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassCapsule()
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
        .contextMenu {
            Button {
                editingPlace = place
            } label: {
                Label("places.edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                placePendingDeletion = place
            } label: {
                Label("places.delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Add / edit

/// Creates a place (at your position or at the map center) or edits an existing one.
struct PlaceEditorView: View {
    enum Mode {
        case add
        case edit(SavedPlace)
    }

    private enum Source: Hashable {
        case myLocation
        case mapCenter
    }

    let mode: Mode
    let userLocation: GeoPoint?
    let mapCenter: GeoPoint?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = SavedPlace.emojiPalette[0]
    @State private var source: Source = .myLocation
    @State private var isPublic = false
    @State private var isSaving = false
    @State private var didLoad = false
    @FocusState private var isNameFocused: Bool

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var targetPoint: GeoPoint? {
        switch source {
        case .myLocation: userLocation
        case .mapCenter: mapCenter
        }
    }

    private var canSave: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isEditing || targetPoint != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        Text(verbatim: emoji)
                            .font(.system(size: 54))
                            .frame(width: 104, height: 104)
                            .glassCircle()
                            .glow(Theme.neonPurple, radius: 18)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("places.name")
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        TextField("places.name.placeholder", text: $name)
                            .font(Theme.text(.body, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                            .focused($isNameFocused)
                            .padding(14)
                            .glassCard(cornerRadius: Theme.Radius.control)
                            .onChange(of: name) { _, value in
                                if value.count > 40 {
                                    name = String(value.prefix(40))
                                }
                            }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("places.icon")
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                            ForEach(SavedPlace.emojiPalette, id: \.self) { option in
                                let isSelected = option == emoji
                                Button {
                                    HapticManager.shared.selection()
                                    withAnimation(Theme.spring) {
                                        emoji = option
                                    }
                                } label: {
                                    Text(verbatim: option)
                                        .font(.system(size: 24))
                                        .frame(maxWidth: .infinity, minHeight: 46)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(isSelected ? Theme.electricViolet.opacity(0.35) : Color.white.opacity(0.05))
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(isSelected ? Theme.neonPurple : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                                        }
                                }
                                .buttonStyle(PressableButtonStyle())
                                .accessibilityLabel(Text(verbatim: option))
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                            }
                        }
                        .padding(14)
                        .glassCard()
                    }

                    visibilityCard

                    if !isEditing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("places.where")
                                .font(Theme.text(.subheadline, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Picker(selection: $source) {
                                Text("places.where.myLocation").tag(Source.myLocation)
                                Text("places.where.mapCenter").tag(Source.mapCenter)
                            } label: {
                                Text("places.where")
                            }
                            .pickerStyle(.segmented)
                            Group {
                                if targetPoint == nil {
                                    Text(source == .myLocation ? "places.where.noLocation" : "places.where.noMap")
                                        .foregroundStyle(Theme.warning)
                                } else if source == .mapCenter {
                                    Text("places.where.mapCenterHint")
                                        .foregroundStyle(Theme.textSecondary)
                                } else {
                                    Text("places.where.myLocationHint")
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .font(Theme.text(.caption))
                        }
                    }

                    Button {
                        save()
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .tint(Color.white)
                            }
                            Text(isEditing ? "profile.save" : "places.add")
                        }
                    }
                    .buttonStyle(PrimaryGradientButtonStyle())
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.55)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.obsidian.ignoresSafeArea())
            .navigationTitle(isEditing ? Text("places.edit") : Text("places.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("common.cancel")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if case .edit(let place) = mode {
                name = place.name
                emoji = place.emoji
                isPublic = place.isPublic
            } else {
                if userLocation == nil, mapCenter != nil {
                    source = .mapCenter
                }
                isNameFocused = true
            }
        }
    }

    private var visibilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("places.visibility")
                .font(Theme.text(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Picker(selection: $isPublic) {
                Label("places.private", systemImage: "lock.fill").tag(false)
                Label("places.public", systemImage: "globe.europe.africa.fill").tag(true)
            } label: {
                Text("places.visibility")
            }
            .pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isPublic ? "eye.fill" : "lock.fill")
                    .foregroundStyle(isPublic ? Theme.warning : Theme.emerald)
                Text(isPublic ? "places.public.hint" : "places.private.hint")
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.text(.caption))
        }
        .animation(Theme.spring, value: isPublic)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        isNameFocused = false
        Task {
            switch mode {
            case .add:
                if let targetPoint, await appState.addPlace(name: name, emoji: emoji, at: targetPoint, isPublic: isPublic) {
                    dismiss()
                }
            case .edit(let place):
                await appState.updatePlace(place, name: name, emoji: emoji, isPublic: isPublic)
                dismiss()
            }
            isSaving = false
        }
    }
}
