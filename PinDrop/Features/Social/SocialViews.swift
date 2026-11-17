import SwiftUI

// MARK: - Notifications

/// The bell: friend requests, pings, best friends and public places you reached.
struct NotificationsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UserProfile] = []
    @State private var addedPlaceIDs: Set<UUID> = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if appState.notifications.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(appState.notifications) { item in
                            row(item)
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Theme.ink.opacity(0.06))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await appState.deleteNotification(item) }
                                    } label: {
                                        Label("common.delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await appState.reloadNotifications()
                    }
                }
            }
            .navigationTitle(Text("notifications.title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UserProfile.self) { user in
                ProfileView(user: user)
            }
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
        .preferredColorScheme(.light)
        .task {
            await appState.reloadNotifications()
            try? await Task.sleep(for: .seconds(1.2))
            await appState.markNotificationsRead()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            Text("notifications.empty.title")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("notifications.empty.body")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: AppNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if let actor = item.actor {
                    path.append(actor)
                }
            } label: {
                leadingIcon(item)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(item.actor == nil)

            VStack(alignment: .leading, spacing: 6) {
                message(item)
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: LocaleFormatter.relativeTimestamp(item.createdAt))
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                actions(item)
            }
            Spacer(minLength: 0)
            if item.isUnread {
                Circle()
                    .fill(Theme.neonPurple)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityLabel(Text("notifications.new"))
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func leadingIcon(_ item: AppNotification) -> some View {
        if let actor = item.actor {
            AvatarBadge(user: actor, size: 42)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: symbol(for: item.kind))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.accentGradient))
                        .overlay(Circle().strokeBorder(Theme.obsidian, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
        } else {
            Image(systemName: symbol(for: item.kind))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.accentGradient))
        }
    }

    private func symbol(for kind: AppNotification.Kind) -> String {
        switch kind {
        case .friendRequest: "person.badge.plus"
        case .friendAccepted: "person.2.fill"
        case .ping: "figure.walk"
        case .placeReached: "mappin.and.ellipse"
        case .bestFriend: "heart.fill"
        }
    }

    private func message(_ item: AppNotification) -> Text {
        let name = item.actor?.displayName ?? String(localized: "notifications.someone")
        switch item.kind {
        case .friendRequest:
            return Text("notifications.friendRequest \(name)")
        case .friendAccepted:
            return Text("notifications.friendAccepted \(name)")
        case .ping:
            if let eta = item.payload?.etaSeconds {
                return Text("notifications.pingEta \(name) \(LocaleFormatter.walkingDuration(seconds: TimeInterval(eta)))")
            }
            return Text("notifications.ping \(name)")
        case .placeReached:
            let placeName = item.place.map { "\($0.emoji) \($0.name)" } ?? "📍"
            return Text("notifications.placeReached \(placeName) \(name)")
        case .bestFriend:
            return Text("notifications.bestFriend \(name)")
        }
    }

    private func alreadySaved(_ place: PlaceSummary) -> Bool {
        addedPlaceIDs.contains(place.id) || appState.places.contains {
            GeoClustering.haversineDistance(from: $0.location, to: place.location) < 30
        }
    }

    @ViewBuilder
    private func actions(_ item: AppNotification) -> some View {
        switch item.kind {
        case .friendRequest:
            if let actor = item.actor, appState.friendsSnapshot.incoming.contains(where: { $0.requesterID == actor.id }) {
                HStack(spacing: 8) {
                    Button {
                        HapticManager.shared.success()
                        Task { await appState.acceptFriendRequest(from: actor) }
                    } label: {
                        Text("friends.requests.accept")
                    }
                    .buttonStyle(SmallPillButtonStyle(isProminent: true))
                    Button {
                        if let request = appState.friendsSnapshot.incoming.first(where: { $0.requesterID == actor.id }) {
                            Task {
                                await appState.respond(to: request, accept: false)
                                await appState.deleteNotification(item)
                            }
                        }
                    } label: {
                        Text("friends.requests.decline")
                    }
                    .buttonStyle(SmallPillButtonStyle(isProminent: false))
                }
            }
        case .placeReached:
            if let place = item.place {
                if alreadySaved(place) {
                    Label("notifications.placeSaved", systemImage: "checkmark.circle.fill")
                        .font(Theme.text(.caption, weight: .semibold))
                        .foregroundStyle(Theme.emerald)
                } else {
                    Button {
                        HapticManager.shared.success()
                        Task {
                            if await appState.addPlace(from: place) {
                                addedPlaceIDs.insert(place.id)
                            }
                        }
                    } label: {
                        Label("publicPlace.add", systemImage: "plus")
                    }
                    .buttonStyle(SmallPillButtonStyle(isProminent: true))
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Compact capsule button used in notification rows.
struct SmallPillButtonStyle: ButtonStyle {
    var isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text(.footnote, weight: .bold))
            .foregroundStyle(isProminent ? Color.white : Theme.neonPurple)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Capsule())
            .glassCapsule(interactive: true, tint: isProminent ? Theme.electricViolet : nil)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Profiles

/// Another user's profile in its own sheet.
struct ProfileSheet: View {
    let user: UserProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProfileView(user: user)
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
        .preferredColorScheme(.light)
    }
}

/// Profile of any user: avatar, bio, profile views, public places, best friend status.
/// Opening it counts as a view (once a day).
struct ProfileView: View {
    let user: UserProfile

    @Environment(AppState.self) private var appState
    @State private var profile: UserProfile?
    @State private var places: [PlaceSummary] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var addedPlaceIDs: Set<UUID> = []
    @State private var isConfirmingRemoval = false

    private var shown: UserProfile { profile ?? user }
    private var isMe: Bool { user.id == appState.currentUser.id }
    private var isFriend: Bool { appState.friendsSnapshot.friendshipIDs[user.id] != nil }
    private var incomingRequest: Friendship? { appState.friendsSnapshot.incoming.first { $0.requesterID == user.id } }
    private var isRequested: Bool { appState.friendsSnapshot.outgoing.contains { $0.addresseeID == user.id } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if let music = appState.nowPlaying(for: user.id) {
                    NowPlayingCard(nowPlaying: music)
                }
                if !isMe {
                    friendshipCard
                }
                placesSection
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.obsidian.opacity(0.001))
        .navigationTitle(Text(verbatim: shown.handle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: user.id) {
            let details = await appState.loadProfileDetails(for: user)
            withAnimation(Theme.spring) {
                profile = details.profile
                places = details.places
                isLoading = false
            }
        }
        .confirmationDialog(
            Text("friends.remove.title"),
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await appState.removeFriend(shown) }
            } label: {
                Text("friends.remove")
            }
            Button(role: .cancel) {} label: {
                Text("common.cancel")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            LiveAvatarView(user: shown, size: 96)
                .padding(4)
                .overlay {
                    Circle().strokeBorder(Theme.accentGradient, lineWidth: 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !shown.statusEmoji.isEmpty {
                        Text(verbatim: shown.statusEmoji)
                            .font(.system(size: 22))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.surface))
                            .offset(x: 4, y: 4)
                    }
                }
            HStack(spacing: 6) {
                Text(verbatim: shown.displayName)
                    .font(Theme.rounded(.title2, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                if !isMe, appState.isBestFriend(user.id) {
                    Text(verbatim: "💜")
                        .accessibilityLabel(Text("bestFriend.badge"))
                }
            }
            Text(verbatim: shown.handle)
                .font(Theme.rounded(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if !shown.bio.isEmpty {
                Text(verbatim: shown.bio)
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                statPill(systemImage: "eye.fill", text: Text("hud.profileViews \(shown.viewCount)"))
                statPill(systemImage: "mappin.and.ellipse", text: Text("profile.publicPlaces \(places.count)"))
            }
            .redacted(reason: isLoading ? .placeholder : [])
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard()
    }

    private func statPill(systemImage: String, text: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.neonPurple)
            text
        }
        .font(Theme.rounded(.footnote, weight: .bold))
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassCapsule()
        .fixedSize()
    }

    @ViewBuilder
    private var friendshipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isFriend {
                if appState.locationPermission(of: user.id) != "always" {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("locationReminder.profileTitle")
                                .font(Theme.text(.footnote, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                            LocationPermissionLabel(permission: appState.locationPermission(of: user.id))
                        }
                        Spacer(minLength: 8)
                        RemindFriendButton(friend: shown)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.danger.opacity(0.15)))
                }
                BestFriendProgressView(time: appState.friendTime(with: user.id), name: shown.firstName)
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Label("friends.remove", systemImage: "person.badge.minus")
                        .font(Theme.text(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                }
            } else if let incomingRequest {
                Button {
                    isWorking = true
                    Task {
                        await appState.respond(to: incomingRequest, accept: true)
                        isWorking = false
                    }
                } label: {
                    Label("friends.requests.accept", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryGradientButtonStyle())
                .disabled(isWorking)
            } else if isRequested {
                Label("profile.requestSent", systemImage: "clock.fill")
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    isWorking = true
                    Task {
                        _ = await appState.sendFriendRequest(to: shown.username)
                        isWorking = false
                    }
                } label: {
                    Label("contacts.add", systemImage: "person.badge.plus")
                }
                .buttonStyle(PrimaryGradientButtonStyle())
                .disabled(isWorking)
            }
        }
        .padding(16)
        .glassCard()
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("profile.placesTitle")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 4)
            if places.isEmpty {
                Text(isLoading ? "common.loading" : "profile.noPublicPlaces")
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .glassCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(places) { place in
                        placeRow(place)
                        if place.id != places.last?.id {
                            Divider()
                                .overlay(Theme.ink.opacity(0.06))
                                .padding(.leading, 66)
                        }
                    }
                }
                .glassCard()
            }
        }
    }

    private func placeRow(_ place: PlaceSummary) -> some View {
        let saved = addedPlaceIDs.contains(place.id) || appState.places.contains {
            GeoClustering.haversineDistance(from: $0.location, to: place.location) < 30
        }
        return HStack(spacing: 12) {
            Button {
                HapticManager.shared.tap()
                appState.showOnMap(place.location)
            } label: {
                HStack(spacing: 12) {
                    Text(verbatim: place.emoji)
                        .font(.system(size: 22))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Theme.ink.opacity(0.06)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: place.name)
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let distance = appState.distanceText(to: place.location) {
                            Text(verbatim: distance)
                                .font(Theme.text(.caption))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))

            if isMe {
                EmptyView()
            } else if saved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.emerald)
                    .accessibilityLabel(Text("notifications.placeSaved"))
            } else {
                Button {
                    HapticManager.shared.success()
                    Task {
                        if await appState.addPlace(from: place) {
                            addedPlaceIDs.insert(place.id)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(CircleGlassButtonStyle(diameter: 34))
                .accessibilityLabel(Text("publicPlace.add"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Time spent together and how close you are to becoming best friends.
struct BestFriendProgressView: View {
    let time: FriendTime?
    let name: String

    private var seconds: Int { time?.seconds ?? 0 }
    private var isBest: Bool { time?.isBestFriend ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: isBest ? "💜" : "🤝")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                        .font(Theme.text(.subheadline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("bestFriend.together \(BestFriendProgressView.duration(seconds))")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !isBest {
                ProgressView(value: Double(min(seconds, FriendTime.bestFriendSeconds)), total: Double(FriendTime.bestFriendSeconds))
                    .tint(Theme.neonPurple)
                Text("bestFriend.hint \(BestFriendProgressView.duration(max(0, FriendTime.bestFriendSeconds - seconds)))")
                    .font(Theme.text(.caption2))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleText: Text {
        if isBest {
            return Text("bestFriend.title \(name)")
        }
        return Text("bestFriend.progressTitle")
    }

    static func duration(_ seconds: Int) -> String {
        let rounded = max(0, (Double(seconds) / 60).rounded(.down) * 60)
        if rounded < 60 {
            return Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .abbreviated, zeroValueUnits: .show(length: 1)))
        }
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Public place visitors

/// Who has been at a public place and how many times: your friends, or everyone,
/// from who has been there the most to who has been there the least.
struct PlaceVisitorsSection: View {
    private enum Scope: Hashable {
        case friends
        case everyone
    }

    let placeID: UUID

    @Environment(AppState.self) private var appState
    @State private var visitors: [PlaceVisitor] = []
    @State private var isLoading = true
    @State private var scope: Scope = .friends

    private var shown: [PlaceVisitor] {
        switch scope {
        case .friends: visitors.filter { $0.isFriend || $0.isMe }
        case .everyone: visitors
        }
    }

    private var totalVisits: Int {
        shown.reduce(0) { $0 + $1.visitCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("visitors.title", systemImage: "trophy.fill")
                    .font(Theme.text(.headline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if !shown.isEmpty {
                    Text("places.visits \(totalVisits)")
                        .font(Theme.text(.caption, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Picker(selection: $scope) {
                Text("visitors.friends").tag(Scope.friends)
                Text("visitors.everyone").tag(Scope.everyone)
            } label: {
                Text("visitors.title")
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) {
                HapticManager.shared.selection()
            }

            if isLoading && visitors.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if shown.isEmpty {
                Text(scope == .friends ? "visitors.empty.friends" : "visitors.empty.everyone")
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, visitor in
                        row(visitor, rank: index + 1)
                    }
                }
            }
        }
        .padding(16)
        .glassCard()
        .animation(Theme.spring, value: scope)
        .task(id: placeID) {
            isLoading = true
            if let fetched = try? await appState.dataService.fetchPlaceVisitors(placeID) {
                withAnimation(Theme.spring) {
                    visitors = fetched
                }
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private func row(_ visitor: PlaceVisitor, rank: Int) -> some View {
        let content = HStack(spacing: 12) {
            rankBadge(rank)
            AvatarBadge(user: visitor.profile, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if visitor.isMe {
                        Text("visitors.you")
                    } else {
                        Text(verbatim: visitor.displayName)
                    }
                }
                .font(Theme.text(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                if let last = visitor.lastVisitAt {
                    Text("places.lastVisit \(LocaleFormatter.relativeTimestamp(last, relativeTo: .now))")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("places.visits \(visitor.visitCount)")
                .font(Theme.rounded(.subheadline, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassCapsule()
                .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())

        if visitor.isMe {
            content
        } else {
            NavigationLink(value: visitor.profile) {
                content
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
        }
    }

    @ViewBuilder
    private func rankBadge(_ rank: Int) -> some View {
        Group {
            switch rank {
            case 1: Text(verbatim: "🥇").font(.system(size: 22))
            case 2: Text(verbatim: "🥈").font(.system(size: 22))
            case 3: Text(verbatim: "🥉").font(.system(size: 22))
            default:
                Text(verbatim: "\(rank)")
                    .font(Theme.rounded(.subheadline, weight: .heavy))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 28)
    }
}

// MARK: - Public place sheet

/// Someone else's public place tapped on the map.
struct PublicPlaceSheet: View {
    let place: PublicPlace

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var didSave = false

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

    private var alreadySaved: Bool {
        didSave || appState.places.contains {
            GeoClustering.haversineDistance(from: $0.location, to: place.location) < 30
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Text(verbatim: place.emoji)
                            .font(.system(size: 50))
                            .frame(width: 96, height: 96)
                            .glassCircle()
                        Text(verbatim: place.name)
                            .font(Theme.rounded(.title2, weight: .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                        if let distance = appState.distanceText(to: place.location) {
                            Label {
                                Text(verbatim: distance)
                            } icon: {
                                Image(systemName: "location.fill")
                            }
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        }
                        Label("places.public", systemImage: "globe.europe.africa.fill")
                            .font(Theme.text(.caption, weight: .semibold))
                            .foregroundStyle(Theme.emerald)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .glassCard()

                    NavigationLink(value: owner) {
                        HStack(spacing: 12) {
                            AvatarBadge(user: owner, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("publicPlace.addedBy")
                                    .font(Theme.text(.caption))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(verbatim: place.ownerDisplayName)
                                    .font(Theme.text(.subheadline, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(14)
                        .glassCard()
                    }
                    .buttonStyle(PressableButtonStyle(pressedScale: 0.98))

                    PlaceVisitorsSection(placeID: place.id)

                    if alreadySaved {
                        Label("notifications.placeSaved", systemImage: "checkmark.circle.fill")
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.emerald)
                    } else {
                        Button {
                            isSaving = true
                            Task {
                                if await appState.addPlace(from: place) {
                                    HapticManager.shared.success()
                                    didSave = true
                                }
                                isSaving = false
                            }
                        } label: {
                            Label("publicPlace.add", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryGradientButtonStyle())
                        .disabled(isSaving)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: UserProfile.self) { user in
                ProfileView(user: user)
            }
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
        .preferredColorScheme(.light)
    }
}
