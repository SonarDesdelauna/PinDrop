import Contacts
import MessageUI
import SwiftUI

// MARK: - Friend on the map

/// Friends on the map: one small avatar, or several side by side when they stand together
/// (annotation content: no environment access).
struct FriendGroupAnnotationView: View {
    let users: [UserProfile]
    let updatedAt: Date
    let onlineIDs: Set<UUID>
    var music: NowPlaying?

    private let avatarSize: CGFloat = 28

    private var isAnyoneOnline: Bool {
        users.contains { onlineIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: -7) {
                ForEach(users.prefix(5)) { user in
                    AvatarBadge(user: user, size: avatarSize)
                        .padding(2)
                        .background(Circle().fill(onlineIDs.contains(user.id) ? Theme.emerald : Color.white))
                }
                if users.count > 5 {
                    Text(verbatim: "+\(users.count - 5)")
                        .font(Theme.roundedFixed(11, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: avatarSize + 4, height: avatarSize + 4)
                        .background(Circle().fill(Theme.accentGradient))
                }
            }
            .overlay {
                if music != nil, users.count == 1 {
                    ListeningHeadphones(size: avatarSize + 4)
                }
            }
            .padding(users.count > 1 ? 3 : 0)
            .background {
                if users.count > 1 {
                    Capsule().fill(Color.white.opacity(0.75))
                }
            }
            .shadow(color: (isAnyoneOnline ? Theme.emerald : Color.black).opacity(0.45), radius: 6)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 4) {
                    if isAnyoneOnline {
                        Circle()
                            .fill(Theme.emerald)
                            .frame(width: 5, height: 5)
                    }
                    Text(verbatim: users.count > 2
                        ? "\(users[0].firstName) +\(users.count - 1)"
                        : users.map(\.firstName).joined(separator: " & "))
                    if !isAnyoneOnline {
                        Text(verbatim: "·")
                            .foregroundStyle(Theme.textSecondary)
                        Text(verbatim: LocaleFormatter.relativeTimestamp(updatedAt, relativeTo: context.date))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(Theme.roundedFixed(9, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassCapsule()
                .fixedSize()
            }
            if let music {
                HStack(spacing: 4) {
                    EqualizerBars(tint: music.providerTint)
                        .scaleEffect(0.7)
                    Text(verbatim: music.track)
                        .lineLimit(1)
                }
                .font(Theme.roundedFixed(9, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: 120)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassCapsule()
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Red warning banner

/// Red in-app warning with a triangle, an action and a close button.
struct LocationWarningBanner: View {
    let title: LocalizedStringKey
    let message: Text
    let actionTitle: LocalizedStringKey
    let action: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.danger))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Color.white)
                message
                    .font(Theme.text(.caption))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.text(.footnote, weight: .heavy))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(PressableButtonStyle())
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.black.opacity(0.2)))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("common.close"))
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.danger.opacity(0.88))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: Theme.danger.opacity(0.45), radius: 16, x: 0, y: 6)
    }
}

// MARK: - Remind friends

/// Friends who don't share their location with "Always", with a button to text them.
struct LocationRemindersView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                        Text("locationReminder.explain")
                            .font(Theme.text(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)

                    if appState.friendsWithoutAlways.isEmpty {
                        Label("locationReminder.allSet", systemImage: "checkmark.circle.fill")
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.emerald)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .glassCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(appState.friendsWithoutAlways) { friend in
                                HStack(spacing: 12) {
                                    AvatarBadge(user: friend, size: 42)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: friend.displayName)
                                            .font(Theme.text(.subheadline, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1)
                                        LocationPermissionLabel(permission: appState.locationPermission(of: friend.id))
                                    }
                                    Spacer(minLength: 8)
                                    RemindFriendButton(friend: friend)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                if friend.id != appState.friendsWithoutAlways.last?.id {
                                    Divider()
                                        .overlay(Color.white.opacity(0.06))
                                        .padding(.leading, 68)
                                }
                            }
                        }
                        .glassCard()
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(Text("locationReminder.title"))
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
        .preferredColorScheme(.light)
    }
}

/// "Only while using the app" / "Location off" / "Not updated yet", in red.
struct LocationPermissionLabel: View {
    let permission: String?

    var body: some View {
        Group {
            switch permission {
            case "when_in_use": Text("locationReminder.status.whenInUse")
            case "denied": Text("locationReminder.status.denied")
            default: Text("locationReminder.status.unknown")
            }
        }
        .font(Theme.text(.caption, weight: .semibold))
        .foregroundStyle(Theme.danger)
        .lineLimit(1)
    }
}

/// Opens an SMS asking the friend to switch their location to "Always". The phone number is
/// found in your contacts when possible (matched by hash), otherwise you pick the recipient.
struct RemindFriendButton: View {
    let friend: UserProfile

    private struct Draft: Identifiable {
        let id = UUID()
        let recipients: [String]
    }

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var draft: Draft?
    @State private var isLooking = false

    private var message: String {
        String(localized: "locationReminder.sms \(friend.firstName)")
    }

    var body: some View {
        Button {
            remind()
        } label: {
            if isLooking {
                ProgressView()
                    .tint(Color.white)
            } else {
                Label("locationReminder.remind", systemImage: "message.fill")
            }
        }
        .buttonStyle(SmallPillButtonStyle(isProminent: true))
        .disabled(isLooking)
        .sheet(item: $draft) { draft in
            MessageComposer(recipients: draft.recipients, body: message) {
                self.draft = nil
            }
            .ignoresSafeArea()
        }
    }

    private func remind() {
        HapticManager.shared.tap()
        isLooking = true
        Task {
            let phone = await ContactPhoneFinder.phone(for: friend.id, dataService: appState.dataService)
            isLooking = false
            if MFMessageComposeViewController.canSendText() {
                draft = Draft(recipients: phone.map { [$0] } ?? [])
            } else {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&=?")
                let body = message.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                let number = phone?.filter { $0.isNumber || $0 == "+" } ?? ""
                if let url = URL(string: "sms:\(number)&body=\(body)") {
                    openURL(url)
                }
            }
        }
    }
}

/// Finds a PinDrop user's phone number in your address book (only if contacts access was
/// already granted), by matching hashes on the server.
enum ContactPhoneFinder {
    @MainActor
    static func phone(for profileID: UUID, dataService: SupabaseDataService) async -> String? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return nil }
        guard let contacts = try? await Task.detached(priority: .userInitiated, operation: {
            try ContactsView.readContacts()
        }).value else { return nil }
        var phoneByHash: [String: String] = [:]
        for contact in contacts {
            for phone in contact.phones {
                if let hash = ContactHasher.phoneHash(phone) {
                    phoneByHash[hash] = phone
                }
            }
        }
        guard !phoneByHash.isEmpty,
              let matches = try? await dataService.matchContacts(emailHashes: [], phoneHashes: Array(phoneByHash.keys)) else {
            return nil
        }
        return matches.first { $0.profileID == profileID }.flatMap { phoneByHash[$0.matchedHash] }
    }
}
