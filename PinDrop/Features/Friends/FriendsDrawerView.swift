import CoreImage.CIFilterBuiltins
import MapKit
import SwiftUI
import UIKit

/// Profile & friends sheet: live status, add friends, requests, invite code, settings, sign-out.
struct FriendsDrawerView: View {
    @Environment(AppState.self) private var appState
    @Environment(AuthService.self) private var authService
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyInvite = false
    @State private var friendQuery = ""
    @State private var isSendingRequest = false
    @State private var requestResult: FriendRequestResult?
    @State private var friendPendingRemoval: UserProfile?
    @State private var isConfirmingSignOut = false
    @State private var isContactsPresented = false
    @State private var profilePath: [UserProfile] = []
    @State private var showsSuggestions = false
    @State private var requestedSuggestions: Set<UUID> = []
    @State private var isSettingsPresented = false
    @State private var isQRPresented = false
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        @Bindable var state = appState

        NavigationStack(path: $profilePath) {
            ScrollView {
                VStack(spacing: 16) {
                    profileHeader
                    placesHeroCard
                    HStack(alignment: .top, spacing: 12) {
                        bestFriendTile
                        viewsTile
                    }
                    if !appState.friendsSnapshot.incoming.isEmpty {
                        incomingSection
                    }
                    addFriendCard
                    contactsCard
                    friendsSection
                    if !appState.friendsSnapshot.outgoing.isEmpty {
                        outgoingSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await appState.refresh()
            }
            .background(Theme.obsidian.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                floatingActions
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UserProfile.self) { user in
                ProfileView(user: user)
            }
            .navigationDestination(isPresented: $isContactsPresented) {
                ContactsView()
            }
            .navigationDestination(isPresented: $isSettingsPresented) {
                settingsScreen
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        HapticManager.shared.tap()
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel(Text("settings.title"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel(Text("common.close"))
                }
            }
        }
        .sheet(isPresented: $isQRPresented) {
            InviteQRSheet(
                user: appState.currentUser,
                payload: inviteQRPayload
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $state.isProfileEditorPresented) {
            EditProfileView(mode: .edit)
        }
        .confirmationDialog(
            Text("friends.remove.title"),
            isPresented: Binding(
                get: { friendPendingRemoval != nil },
                set: { if !$0 { friendPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: friendPendingRemoval
        ) { friend in
            Button(role: .destructive) {
                Task { await appState.removeFriend(friend) }
            } label: {
                Text("friends.remove.confirm \(friend.displayName)")
            }
            Button(role: .cancel) {} label: {
                Text("common.cancel")
            }
        } message: { friend in
            Text("friends.remove.message \(friend.firstName)")
        }
        .confirmationDialog(Text("auth.signOut.title"), isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button(role: .destructive) {
                dismiss()
                Task { await authService.signOut() }
            } label: {
                Text("auth.signOut")
            }
            Button(role: .cancel) {} label: {
                Text("common.cancel")
            }
        }
    }

    // MARK: - Profile

    private var profileHeader: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                LiveAvatarView(user: appState.currentUser, size: 96)
                    .padding(5)
                    .overlay {
                        Circle().strokeBorder(
                            appState.isUnlocked ? AnyShapeStyle(Theme.emeraldGradient) : AnyShapeStyle(Theme.accentGradient),
                            lineWidth: 3
                        )
                    }
                    .shadow(color: Theme.electricViolet.opacity(0.25), radius: 16, y: 8)
                Button {
                    HapticManager.shared.tap()
                    appState.isProfileEditorPresented = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accentGradient))
                        .overlay(Circle().strokeBorder(Theme.obsidian, lineWidth: 3))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(Text("profile.edit"))
            }
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: appState.currentUser.displayName)
                        .font(Theme.text(.title2, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !appState.currentUser.statusEmoji.isEmpty {
                        Text(verbatim: appState.currentUser.statusEmoji)
                            .font(.system(size: 20))
                    }
                }
                Text(verbatim: appState.currentUser.handle)
                    .font(Theme.rounded(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                if !appState.currentUser.bio.isEmpty {
                    Text(verbatim: appState.currentUser.bio)
                        .font(Theme.text(.footnote))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            statusChip
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var statusChip: some View {
        Group {
            if let ownPin = appState.ownActivePin {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.emerald)
                        .frame(width: 7, height: 7)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("profile.status.live \(LocaleFormatter.remaining(until: ownPin.expiresAt, from: context.date))")
                    }
                }
                .foregroundStyle(Theme.emerald)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("profile.status.locked")
                }
                .foregroundStyle(Theme.neonPurple)
            }
        }
        .font(Theme.text(.caption, weight: .bold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Places hero

    private var totalVisits: Int {
        appState.places.reduce(0) { $0 + $1.visitCount }
    }

    /// The region that frames your saved places (or where you are).
    private var placesRegion: MKCoordinateRegion? {
        let points = appState.places.map(\.location)
        guard !points.isEmpty else {
            return appState.userLocation.map {
                MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 2_500, longitudinalMeters: 2_500)
            }
        }
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return nil }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.012, (maxLat - minLat) * 1.6),
            longitudeDelta: max(0.012, (maxLon - minLon) * 1.6)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Emoji "stamps" of your favourite places, scattered on the card.
    private var placeStamps: [String] {
        let favourites = appState.places.sorted { $0.visitCount > $1.visitCount }.map(\.emoji)
        var stamps: [String] = []
        for emoji in favourites + ["📍", "☕️", "🍕", "🎉"] where !stamps.contains(emoji) {
            stamps.append(emoji)
            if stamps.count == 4 { break }
        }
        return stamps
    }

    private var placesHeroCard: some View {
        Button {
            HapticManager.shared.tap()
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                appState.isPlacesPresented = true
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let region = placesRegion {
                    Map(initialPosition: .region(region), interactionModes: []) {
                        ForEach(appState.places) { place in
                            Annotation("", coordinate: place.coordinate, anchor: .center) {
                                Text(verbatim: place.emoji)
                                    .font(.system(size: 14))
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(Color.white))
                                    .shadow(color: Color.black.opacity(0.18), radius: 3, y: 1)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .allowsHitTesting(false)
                } else {
                    Theme.accentGradient
                }

                LinearGradient(
                    colors: [Theme.electricViolet.opacity(0.15), Theme.electricViolet.opacity(0.65), Theme.electricViolet.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Stamps of your favourite places, like stickers on a passport.
                ForEach(Array(placeStamps.enumerated()), id: \.offset) { index, emoji in
                    let spots: [(CGFloat, CGFloat, Double)] = [(0.80, 0.22, -12), (0.62, 0.12, 10), (0.90, 0.50, 14), (0.70, 0.42, -6)]
                    let spot = spots[index % spots.count]
                    GeometryReader { proxy in
                        Text(verbatim: emoji)
                            .font(.system(size: index == 0 ? 40 : 30))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white)
                                    .shadow(color: Color.black.opacity(0.2), radius: 6, y: 3)
                            )
                            .rotationEffect(.degrees(spot.2))
                            .position(x: proxy.size.width * spot.0, y: proxy.size.height * spot.1 + 20)
                    }
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("places.title")
                        .font(Theme.text(.subheadline, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Text(verbatim: "\(appState.places.count)")
                        .font(.system(size: 54, weight: .black, design: .rounded))
                        .foregroundStyle(Color.white)
                        .contentTransition(.numericText())
                    HStack(spacing: 6) {
                        Image(systemName: "figure.walk")
                        Text("places.visits \(totalVisits)")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .heavy))
                    }
                    .font(Theme.text(.footnote, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))
                }
                .padding(18)
            }
            .frame(height: 196)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: Theme.electricViolet.opacity(0.28), radius: 18, y: 10)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
    }

    // MARK: - Tiles

    private func tile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(14)
        .glassCard()
    }

    @ViewBuilder
    private var bestFriendTile: some View {
        if let best = appState.bestFriend {
            Button {
                HapticManager.shared.tap()
                profilePath.append(best.profile)
            } label: {
                tile {
                    HStack(spacing: -10) {
                        AvatarBadge(user: appState.currentUser, size: 40)
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                        AvatarBadge(user: best.profile, size: 40)
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(verbatim: best.time.isBestFriend ? "💜" : "🤝")
                            .font(.system(size: 15))
                            .offset(x: 6, y: 4)
                    }
                    Text(best.time.isBestFriend ? "bestFriend.card.title" : "bestFriend.card.closest")
                        .font(Theme.text(.caption, weight: .bold))
                        .foregroundStyle(Theme.neonPurple)
                    Text(verbatim: best.profile.firstName)
                        .font(Theme.text(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("bestFriend.together \(BestFriendProgressView.duration(best.time.seconds))")
                        .font(Theme.text(.caption2, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
        } else {
            tile {
                Text(verbatim: "💜")
                    .font(.system(size: 22))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.electricViolet.opacity(0.16)))
                Text("bestFriend.card.title")
                    .font(Theme.text(.caption, weight: .bold))
                    .foregroundStyle(Theme.neonPurple)
                Text("bestFriend.card.empty")
                    .font(Theme.text(.caption2))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
        }
    }

    private var viewsTile: some View {
        tile {
            Image(systemName: "eye.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.emeraldGradient))
            Text("drawer.views.title")
                .font(Theme.text(.caption, weight: .bold))
                .foregroundStyle(Theme.emerald)
            Text(verbatim: "\(appState.currentUser.viewCount)")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("friends.section \(appState.friends.count)")
                .font(Theme.text(.caption2, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Floating actions

    private var inviteQRPayload: String {
        "\(AppLinks.appStoreURL.absoluteString)?invite=\(appState.currentUser.inviteCode)"
    }

    private var floatingActions: some View {
        HStack(spacing: 12) {
            ShareLink(item: inviteMessage) {
                Label("drawer.share", systemImage: "square.and.arrow.up")
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 22)
                    .frame(height: 52)
                    .background(Capsule().fill(Theme.accentGradient))
                    .shadow(color: Theme.electricViolet.opacity(0.4), radius: 14, y: 6)
            }
            .buttonStyle(PressableButtonStyle())
            Button {
                HapticManager.shared.tap()
                isQRPresented = true
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 52, height: 52)
                    .glassCircle()
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("drawer.qr"))
        }
        .padding(.bottom, 12)
    }

    // MARK: - Settings screen

    private var settingsScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                inviteCard
                settingsSection
                demoSection
                signOutButton
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.obsidian.ignoresSafeArea())
        .navigationTitle(Text("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Contacts

    private var contactsCard: some View {
        Button {
            HapticManager.shared.tap()
            isContactsPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.accentGradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("contacts.find.title")
                        .font(Theme.text(.subheadline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("contacts.find.subtitle")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .glassCard()
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
    }

    // MARK: - Add friend

    private var trimmedQuery: String {
        friendQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var addFriendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("friends.add.title")
                .font(Theme.text(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(Theme.neonPurple)
                TextField("friends.add.placeholder", text: $friendQuery)
                    .font(Theme.text(.body, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($isQueryFocused)
                    .onSubmit { sendRequest() }
                    .onChange(of: friendQuery) { _, _ in
                        if requestResult != nil {
                            withAnimation(Theme.spring) { requestResult = nil }
                        }
                    }
                Button {
                    sendRequest()
                } label: {
                    if isSendingRequest {
                        ProgressView()
                            .tint(Theme.textPrimary)
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(CircleGlassButtonStyle(diameter: 36))
                .disabled(trimmedQuery.isEmpty || isSendingRequest)
                .accessibilityLabel(Text("friends.add.send"))
            }
            .padding(12)
            .glassCard(cornerRadius: Theme.Radius.control)

            if let requestResult {
                Label {
                    Text(verbatim: requestResult.message)
                } icon: {
                    Image(systemName: requestResult.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                }
                .font(Theme.text(.footnote, weight: .semibold))
                .foregroundStyle(requestResult.isSuccess ? Theme.emerald : Theme.warning)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showsSuggestions {
                suggestionsList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .glassCard()
        .animation(Theme.spring, value: showsSuggestions)
        .onChange(of: isQueryFocused) { _, focused in
            guard focused else { return }
            showsSuggestions = true
            Task { await appState.reloadSuggestions() }
        }
    }

    private var filteredSuggestions: [FriendSuggestion] {
        let query = trimmedQuery.lowercased()
        let available = appState.suggestions.filter { appState.friendsSnapshot.friendshipIDs[$0.profile.id] == nil }
        guard !query.isEmpty else { return available }
        return available.filter {
            $0.profile.username.lowercased().contains(query) || $0.profile.displayName.lowercased().contains(query)
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("friends.suggested.title")
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button {
                    showsSuggestions = false
                    isQueryFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(CircleGlassButtonStyle(diameter: 28))
                .accessibilityLabel(Text("common.close"))
            }
            if filteredSuggestions.isEmpty {
                Text("friends.suggested.empty")
                    .font(Theme.text(.footnote))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ForEach(filteredSuggestions.prefix(8)) { suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: FriendSuggestion) -> some View {
        let user = suggestion.profile
        let isRequested = requestedSuggestions.contains(user.id)
            || appState.friendsSnapshot.outgoing.contains { $0.addresseeID == user.id }
        return HStack(spacing: 10) {
            Button {
                profilePath.append(user)
            } label: {
                HStack(spacing: 10) {
                    AvatarBadge(user: user, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: user.displayName)
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Group {
                            if suggestion.mutualCount > 0 {
                                Text("friends.suggested.mutual \(suggestion.mutualCount)")
                            } else if suggestion.isNearby {
                                Text("friends.suggested.nearby")
                            } else {
                                Text(verbatim: user.handle)
                            }
                        }
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))

            if isRequested {
                Text("contacts.requested")
                    .font(Theme.text(.caption, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button {
                    HapticManager.shared.tap()
                    requestedSuggestions.insert(user.id)
                    Task {
                        let result = await appState.sendFriendRequest(to: user.username)
                        if result?.isSuccess != true {
                            requestedSuggestions.remove(user.id)
                        }
                    }
                } label: {
                    Label("contacts.add", systemImage: "person.badge.plus")
                }
                .buttonStyle(SmallPillButtonStyle(isProminent: true))
            }
        }
    }

    private func sendRequest() {
        let query = trimmedQuery
        guard !query.isEmpty, !isSendingRequest else { return }
        isSendingRequest = true
        Task {
            let result = await appState.sendFriendRequest(to: query)
            isSendingRequest = false
            withAnimation(Theme.spring) {
                requestResult = result
            }
            if result?.isSuccess == true {
                friendQuery = ""
                requestResult = result
                isQueryFocused = false
            }
        }
    }

    // MARK: - Requests

    private var incomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("friends.requests.incoming \(appState.friendsSnapshot.incoming.count)")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(appState.friendsSnapshot.incoming) { request in
                    HStack(spacing: 12) {
                        AvatarBadge(user: request.requester, size: 42)
                        profileLabels(request.requester)
                        Spacer(minLength: 8)
                        Button {
                            Task { await appState.respond(to: request, accept: false) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(CircleGlassButtonStyle(diameter: 36))
                        .accessibilityLabel(Text("friends.requests.decline"))
                        Button {
                            Task { await appState.respond(to: request, accept: true) }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Theme.emeraldGradient))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(Text("friends.requests.accept"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .glassCard()
        }
    }

    private var outgoingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("friends.requests.outgoing")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(appState.friendsSnapshot.outgoing) { request in
                    HStack(spacing: 12) {
                        AvatarBadge(user: request.addressee, size: 42)
                        profileLabels(request.addressee)
                        Spacer(minLength: 8)
                        Button {
                            Task { await appState.cancelRequest(request) }
                        } label: {
                            Text("friends.requests.cancel")
                                .font(Theme.text(.caption, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassCapsule()
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .glassCard()
        }
    }

    private func profileLabels(_ user: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: user.displayName)
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !user.statusEmoji.isEmpty {
                    Text(verbatim: user.statusEmoji)
                        .font(.system(size: 13))
                }
            }
            Text(verbatim: user.handle)
                .font(Theme.rounded(.caption))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - Invite

    private var inviteMessage: String {
        String(localized: "friends.invite.message \(appState.currentUser.inviteCode)")
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("friends.invite.title")
                .font(Theme.text(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 12) {
                Text(verbatim: appState.currentUser.inviteCode)
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = appState.currentUser.inviteCode
                    HapticManager.shared.success()
                    withAnimation(Theme.spring) {
                        didCopyInvite = true
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(Theme.spring) {
                            didCopyInvite = false
                        }
                    }
                } label: {
                    Image(systemName: didCopyInvite ? "checkmark" : "doc.on.doc.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(CircleGlassButtonStyle(diameter: 40))
                .accessibilityLabel(Text("friends.invite.copy"))
            }
            ShareLink(item: inviteMessage) {
                Label("friends.invite.share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryGradientButtonStyle())
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Friends

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("friends.section \(appState.friends.count)")
                    .font(Theme.text(.title3, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if appState.activeFriendsCount > 0 {
                    Text("hud.friendsLive \(appState.activeFriendsCount)")
                        .font(Theme.rounded(.caption, weight: .bold))
                        .foregroundStyle(Theme.emerald)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 4)

            if appState.friends.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("friends.empty")
                        .font(Theme.text(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .glassCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.friends.enumerated()), id: \.element.id) { index, friend in
                        friendRow(friend)
                        if index < appState.friends.count - 1 {
                            Divider()
                                .overlay(Theme.ink.opacity(0.06))
                                .padding(.leading, 66)
                        }
                    }
                }
                .glassCard()
                Text("friends.remove.hint")
                    .font(Theme.text(.caption2))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func friendRow(_ friend: UserProfile) -> some View {
        let activePin = appState.activePin(for: friend)
        let time = appState.friendTime(with: friend.id)
        return Button {
            if let activePin {
                HapticManager.shared.pinTap()
                dismiss()
                appState.requestFocus(on: activePin.id, openViewer: true)
            } else {
                HapticManager.shared.tap()
                profilePath.append(friend)
            }
        } label: {
            HStack(spacing: 12) {
                AvatarBadge(user: friend, size: 42)
                    .overlay {
                        if appState.isOnline(friend.id) {
                            Circle()
                                .strokeBorder(Theme.emerald, lineWidth: 2.5)
                                .padding(-3)
                                .accessibilityLabel(Text("friends.online"))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if activePin != nil {
                            Circle()
                                .fill(Theme.emerald)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(Theme.obsidian, lineWidth: 2))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if time?.isBestFriend == true {
                            Text(verbatim: "💜")
                                .font(.system(size: 13))
                                .offset(x: -4, y: -4)
                                .accessibilityLabel(Text("bestFriend.badge"))
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    profileLabels(friend)
                    if let time, time.seconds >= 60 {
                        Text("bestFriend.together \(BestFriendProgressView.duration(time.seconds))")
                            .font(Theme.text(.caption2, weight: .semibold))
                            .foregroundStyle(time.isBestFriend ? Theme.neonPurple : Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let activePin {
                    VStack(alignment: .trailing, spacing: 2) {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("friends.status.live \(LocaleFormatter.remaining(until: activePin.expiresAt, from: context.date))")
                        }
                        .font(Theme.rounded(.caption, weight: .bold))
                        .foregroundStyle(Theme.emerald)
                        if appState.isUnlocked, let distance = appState.distanceText(to: activePin.location) {
                            Text(verbatim: distance)
                                .font(Theme.rounded(.caption2, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                } else {
                    Text("friends.status.idle")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
        .contextMenu {
            Button {
                profilePath.append(friend)
            } label: {
                Label("profile.view", systemImage: "person.crop.circle")
            }
            Button(role: .destructive) {
                friendPendingRemoval = friend
            } label: {
                Label("friends.remove", systemImage: "person.badge.minus")
            }
        }
    }

    // MARK: - Settings

    private var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier ?? "en"
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return name.capitalized(with: Locale.current)
    }

    private var locationStatusText: Text {
        if locationService.isAuthorized {
            return Text("settings.location.allowed")
        } else if locationService.isDenied {
            return Text("settings.location.denied")
        } else {
            return Text("settings.location.notDetermined")
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.title")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Button {
                    HapticManager.shared.tap()
                    SystemSettings.openAppSettings()
                } label: {
                    settingsRow(
                        icon: "globe",
                        tint: Theme.neonPurple,
                        title: Text("settings.language"),
                        subtitle: Text(verbatim: currentLanguageName),
                        accessory: "arrow.up.forward.app"
                    )
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.98))

                rowDivider

                Button {
                    HapticManager.shared.tap()
                    if locationService.authorizationStatus == .notDetermined {
                        Task { await locationService.requestAuthorization() }
                    } else {
                        SystemSettings.openAppSettings()
                    }
                } label: {
                    settingsRow(
                        icon: "location.fill",
                        tint: Theme.emerald,
                        title: Text("settings.location"),
                        subtitle: locationStatusText,
                        accessory: "chevron.right"
                    )
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.98))

                rowDivider

                settingsLabel(
                    icon: "lock.shield.fill",
                    tint: Theme.emerald,
                    title: Text("settings.privacy"),
                    subtitle: Text("settings.privacy.subtitle")
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassCard()
        }
    }

    // MARK: - Developer / Demo controls

    /// Demo mode puts fake friends, a trail, a cross-path, a capsule and Marco 20 m away around
    /// your real position, so every mechanic can be tried from home.
    private var demoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("demo.section.title")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { appState.isDemoModeEnabled },
                    set: { appState.setDemoMode($0) }
                )) {
                    settingsLabel(
                        icon: "hammer.fill",
                        tint: Theme.warning,
                        title: Text("demo.toggle.title"),
                        subtitle: Text("demo.toggle.subtitle")
                    )
                }
                .tint(Theme.neonPurple)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if appState.isDemoModeEnabled {
                    rowDivider

                    Button {
                        HapticManager.shared.tap()
                        appState.simulateCapsuleApproach()
                    } label: {
                        settingsRow(
                            icon: "shippingbox.fill",
                            tint: Color(hex: 0xF59E0B),
                            title: Text("demo.capsule.simulate"),
                            subtitle: Text("demo.capsule.simulate.subtitle"),
                            accessory: "play.fill"
                        )
                    }
                    .buttonStyle(PressableButtonStyle(pressedScale: 0.98))

                    rowDivider

                    Button {
                        HapticManager.shared.tap()
                        appState.generateDemoCrossPath()
                    } label: {
                        settingsRow(
                            icon: "point.3.connected.trianglepath.dotted",
                            tint: Theme.emerald,
                            title: Text("demo.crossPath.generate"),
                            subtitle: Text("demo.crossPath.generate.subtitle"),
                            accessory: "play.fill"
                        )
                    }
                    .buttonStyle(PressableButtonStyle(pressedScale: 0.98))

                    if appState.simulatedLocation != nil {
                        rowDivider

                        Button {
                            HapticManager.shared.tap()
                            appState.endLocationSimulation()
                        } label: {
                            settingsRow(
                                icon: "location.fill",
                                tint: Theme.neonPurple,
                                title: Text("demo.location.reset"),
                                subtitle: Text("demo.location.reset.subtitle"),
                                accessory: "arrow.uturn.backward"
                            )
                        }
                        .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
                    }
                }
            }
            .glassCard()
            .animation(Theme.spring, value: appState.isDemoModeEnabled)
            .animation(Theme.spring, value: appState.simulatedLocation != nil)
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(Theme.ink.opacity(0.06))
            .padding(.leading, 60)
    }

    private func settingsRow(icon: String, tint: Color, title: Text, subtitle: Text, accessory: String) -> some View {
        HStack(spacing: 12) {
            settingsLabel(icon: icon, tint: tint, title: title, subtitle: subtitle)
            Spacer(minLength: 8)
            Image(systemName: accessory)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func settingsLabel(icon: String, tint: Color, title: Text, subtitle: Text) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                subtitle
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
        }
    }

    // MARK: - Account

    private var signOutButton: some View {
        VStack(spacing: 8) {
            if let email = authService.email {
                Text("auth.signedInAs \(email)")
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button {
                HapticManager.shared.tap()
                isConfirmingSignOut = true
            } label: {
                Label("auth.signOut", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .glassCard(cornerRadius: Theme.Radius.control)
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return VStack(spacing: 4) {
            Text(verbatim: "PinDrop \(version)")
                .font(Theme.rounded(.caption, weight: .semibold))
            Text("settings.footer")
                .font(Theme.text(.caption2))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

/// Your invite as a QR code: a friend scans it and finds you on PinDrop.
private struct InviteQRSheet: View {
    let user: UserProfile
    let payload: String
    @State private var didCopy = false

    private var qrImage: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("drawer.qr.title")
                .font(Theme.text(.title3, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 24)
            ZStack {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                }
                AvatarBadge(user: user, size: 52)
                    .padding(4)
                    .background(Circle().fill(Color.white))
            }
            .frame(width: 240, height: 240)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Theme.accentGradient, lineWidth: 3)
            }
            .shadow(color: Theme.electricViolet.opacity(0.25), radius: 18, y: 8)

            Button {
                UIPasteboard.general.string = user.inviteCode
                HapticManager.shared.success()
                withAnimation(Theme.spring) { didCopy = true }
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: user.inviteCode)
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassCapsule()
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("friends.invite.copy"))

            Text("drawer.qr.subtitle")
                .font(Theme.text(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.obsidian.ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}
