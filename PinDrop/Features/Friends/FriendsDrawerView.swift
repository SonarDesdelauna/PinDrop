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
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        @Bindable var state = appState

        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    addFriendCard
                    if !appState.friendsSnapshot.incoming.isEmpty {
                        incomingSection
                    }
                    friendsSection
                    if !appState.friendsSnapshot.outgoing.isEmpty {
                        outgoingSection
                    }
                    inviteCard
                    settingsSection
                    signOutButton
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await appState.refresh()
            }
            .navigationTitle(Text("friends.title"))
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

    private var profileCard: some View {
        HStack(alignment: .top, spacing: 14) {
            AvatarBadge(user: appState.currentUser, size: 62)
                .padding(3)
                .overlay {
                    Circle().strokeBorder(
                        appState.isUnlocked ? AnyShapeStyle(Theme.emeraldGradient) : AnyShapeStyle(Theme.accentGradient),
                        lineWidth: 2
                    )
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: appState.currentUser.displayName)
                        .font(Theme.text(.title3, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !appState.currentUser.statusEmoji.isEmpty {
                        Text(verbatim: appState.currentUser.statusEmoji)
                            .font(.system(size: 18))
                    }
                }
                Text(verbatim: appState.currentUser.handle)
                    .font(Theme.rounded(.subheadline, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                if !appState.currentUser.bio.isEmpty {
                    Text(verbatim: appState.currentUser.bio)
                        .font(Theme.text(.footnote))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .lineLimit(3)
                }
                if let ownPin = appState.ownActivePin {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.emerald)
                            .frame(width: 7, height: 7)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("profile.status.live \(LocaleFormatter.remaining(until: ownPin.expiresAt, from: context.date))")
                        }
                    }
                    .font(Theme.text(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.emerald)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text("profile.status.locked")
                    }
                    .font(Theme.text(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.neonPurple)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                HapticManager.shared.tap()
                appState.isProfileEditorPresented = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(CircleGlassButtonStyle(diameter: 40))
            .accessibilityLabel(Text("profile.edit"))
        }
        .padding(16)
        .glassCard()
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
        }
        .padding(16)
        .glassCard()
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
                    .font(Theme.text(.headline, weight: .bold))
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
                                .overlay(Color.white.opacity(0.06))
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
        return Button {
            guard let activePin else { return }
            HapticManager.shared.pinTap()
            dismiss()
            appState.requestFocus(on: activePin.id, openViewer: true)
        } label: {
            HStack(spacing: 12) {
                AvatarBadge(user: friend, size: 42)
                    .overlay(alignment: .bottomTrailing) {
                        if activePin != nil {
                            Circle()
                                .fill(Theme.emerald)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(Theme.obsidian, lineWidth: 2))
                        }
                    }
                profileLabels(friend)
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

    private var rowDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.06))
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
