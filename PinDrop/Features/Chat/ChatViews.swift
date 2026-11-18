import MapKit
import SwiftUI
import UIKit

// MARK: - Helpers

private enum ChatStyle {
    static var sentGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x8B5CF6), Color(hex: 0x6D28D9)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let receivedFill = Color(hex: 0x1F1F27).opacity(0.92)
    static let quickReactions = ["❤️", "🔥", "😂", "📍"]
}

extension AppState {
    /// True when the friend is visible on the map right now (live pin or a fresh position).
    func isActiveOnMap(_ userID: UUID) -> Bool {
        if let friend = friends.first(where: { $0.id == userID }), activePin(for: friend) != nil {
            return true
        }
        if let location = friendLocations[userID] {
            return Date.now.timeIntervalSince(location.updatedAt) < 15 * 60
        }
        return false
    }

    /// Where to center the map for a friend: their position, or their live pin.
    func mapPoint(for userID: UUID) -> GeoPoint? {
        if let location = friendLocations[userID] {
            return GeoPoint(latitude: location.latitude, longitude: location.longitude)
        }
        if let friend = friends.first(where: { $0.id == userID }), let pin = activePin(for: friend) {
            return pin.location
        }
        return nil
    }
}

/// One or two overlapping avatars for a conversation.
private struct ThreadAvatar: View {
    let people: [UserProfile]
    let emoji: String
    var size: CGFloat = 50

    var body: some View {
        ZStack {
            if people.count >= 2 {
                AvatarBadge(user: people[1], size: size * 0.72)
                    .offset(x: size * 0.16, y: -size * 0.14)
                AvatarBadge(user: people[0], size: size * 0.72)
                    .overlay { Circle().strokeBorder(Theme.obsidian, lineWidth: 2) }
                    .offset(x: -size * 0.14, y: size * 0.14)
                if !emoji.isEmpty {
                    Text(verbatim: emoji)
                        .font(.system(size: size * 0.3))
                        .offset(x: size * 0.36, y: size * 0.34)
                }
            } else if let person = people.first {
                AvatarBadge(user: person, size: size)
            } else {
                Circle().fill(Theme.surface).frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Chat list

struct ChatListView: View {
    enum Filter: Hashable, CaseIterable {
        case all
        case friends
        case groups

        var title: LocalizedStringKey {
            switch self {
            case .all: "chat.filter.all"
            case .friends: "chat.filter.friends"
            case .groups: "chat.filter.groups"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var isNewChatPresented = false
    @State private var isNewGroupPresented = false

    private var social: SocialStore { appState.social }
    private var me: UUID { appState.currentUser.id }

    private var visibleThreads: [ChatThread] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return social.threads.filter { thread in
            switch filter {
            case .all: break
            case .friends: if thread.type != .direct { return false }
            case .groups: if thread.type == .direct { return false }
            }
            guard !query.isEmpty else { return true }
            if thread.displayTitle(for: me).lowercased().contains(query) { return true }
            return thread.participants.contains { $0.displayName.lowercased().contains(query) || $0.username.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                searchBar
                filterPills
                if visibleThreads.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visibleThreads) { thread in
                                NavigationLink(value: thread.id) {
                                    ChatThreadRow(thread: thread)
                                }
                                .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await social.leave(threadID: thread.id) }
                                    } label: {
                                        Label(thread.type == .direct ? LocalizedStringKey("chat.delete") : LocalizedStringKey("chat.leave"), systemImage: "rectangle.portrait.and.arrow.right")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 24)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .padding(.top, 4)
            .background(Theme.obsidian.ignoresSafeArea())
            .navigationTitle(Text("chat.title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .accessibilityLabel(Text("common.close"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isNewChatPresented = true
                        } label: {
                            Label("chat.new.direct", systemImage: "person.fill")
                        }
                        Button {
                            isNewGroupPresented = true
                        } label: {
                            Label("chat.new.group", systemImage: "person.3.fill")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .bold))
                    }
                    .accessibilityLabel(Text("chat.new"))
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ChatRoomView(threadID: id)
            }
        }
        .tint(Theme.neonPurple)
        .onAppear {
            if let id = social.openThreadID {
                social.openThreadID = nil
                path = [id]
            }
        }
        .onChange(of: social.openThreadID) { _, id in
            guard let id else { return }
            social.openThreadID = nil
            path = [id]
        }
        .sheet(isPresented: $isNewChatPresented) {
            FriendPickerSheet(title: "chat.new.direct", allowsMultiple: false) { picked in
                guard let friend = picked.first else { return }
                Task {
                    do {
                        let id = try await social.openDirectChat(with: friend, isDemo: appState.isDemoFriend(friend.id))
                        path = [id]
                    } catch {
                        appState.showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isNewGroupPresented) {
            CreateGroupChatSheet { id in
                path = [id]
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("chat.search", text: $search)
                .font(Theme.text(.body))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassCapsule()
        .padding(.horizontal, 16)
    }

    private var filterPills: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases, id: \.self) { value in
                let isSelected = filter == value
                Button {
                    HapticManager.shared.selection()
                    withAnimation(Theme.spring) { filter = value }
                } label: {
                    Text(value.title)
                        .font(Theme.rounded(.subheadline, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.accentGradient)
                            } else {
                                Capsule().fill(Theme.surface.opacity(Theme.surfaceOpacity))
                            }
                        }
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accentGradient)
            Text("chat.empty.title")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("chat.empty.body")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                isNewChatPresented = true
            } label: {
                Label("chat.new.direct", systemImage: "plus")
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            .frame(maxWidth: 260)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

private struct ChatThreadRow: View {
    @Environment(AppState.self) private var appState
    let thread: ChatThread

    private var me: UUID { appState.currentUser.id }

    var body: some View {
        let others = thread.others(excluding: me)
        HStack(spacing: 12) {
            ThreadAvatar(people: others, emoji: thread.type == .direct ? "" : thread.emoji)
                .overlay(alignment: .bottomTrailing) {
                    if thread.type == .direct, let friend = others.first, appState.isActiveOnMap(friend.id) {
                        Circle()
                            .fill(Theme.emerald)
                            .frame(width: 13, height: 13)
                            .overlay { Circle().strokeBorder(Theme.obsidian, lineWidth: 2) }
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: thread.displayTitle(for: me))
                        .font(Theme.text(.body, weight: thread.unreadCount > 0 ? .bold : .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if thread.isEphemeral {
                        Image(systemName: "timer")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.warning)
                    }
                }
                Text(verbatim: preview)
                    .font(Theme.text(.subheadline, weight: thread.unreadCount > 0 ? .semibold : .regular))
                    .foregroundStyle(thread.unreadCount > 0 ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(verbatim: LocaleFormatter.relativeTimestamp(thread.lastActivity))
                    .font(Theme.rounded(.caption, weight: .medium))
                    .foregroundStyle(thread.unreadCount > 0 ? Theme.neonPurple : Theme.textSecondary)
                if thread.unreadCount > 0 {
                    Text(verbatim: "\(thread.unreadCount)")
                        .font(Theme.rounded(.caption2, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Theme.accentGradient, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Theme.surface.opacity(thread.unreadCount > 0 ? Theme.surfaceOpacity : 0.0001), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let message = thread.lastMessage else { return String(localized: "chat.preview.new") }
        let prefix: String
        if message.senderID == me {
            prefix = String(localized: "chat.preview.you") + " "
        } else if thread.type != .direct, let sender = thread.participants.first(where: { $0.id == message.senderID }) {
            prefix = sender.firstName + ": "
        } else {
            prefix = ""
        }
        return prefix + ChatMessageText.summary(message)
    }
}

enum ChatMessageText {
    /// One line describing a message, for previews.
    static func summary(_ message: ChatMessage) -> String {
        switch message.content {
        case let .text(text):
            return text
        case let .livePhoto(_, caption):
            return "📸 " + (caption ?? String(localized: "chat.preview.photo"))
        case let .pinReply(_, _, place, text, isStory):
            let base = isStory ? String(localized: "chat.preview.storyReply") : String(localized: "chat.preview.pinReply \(place)")
            return text.isEmpty ? base : "\(base) · \(text)"
        case let .locationPing(_, _, place, eta):
            if let eta {
                return "📍 " + String(localized: "chat.location.eta \(eta)")
            }
            return "📍 " + (place.isEmpty ? String(localized: "chat.location.here") : place)
        case let .voice(_, durationMs, _):
            return String(localized: "chat.voice.preview") + " · " + VoiceFormat.clock(TimeInterval(durationMs) / 1000)
        case .themeChange:
            return String(localized: "chat.theme.preview")
        }
    }
}

// MARK: - Friend picker and new group

struct FriendPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let title: LocalizedStringKey
    let allowsMultiple: Bool
    let onPick: ([UserProfile]) -> Void

    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List(appState.friends) { friend in
                Button {
                    HapticManager.shared.selection()
                    if allowsMultiple {
                        if selected.contains(friend.id) { selected.remove(friend.id) } else { selected.insert(friend.id) }
                    } else {
                        dismiss()
                        onPick([friend])
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarBadge(user: friend, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: friend.displayName)
                                .font(Theme.text(.subheadline, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(verbatim: "@\(friend.username)")
                                .font(Theme.text(.caption))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if allowsMultiple {
                            Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(selected.contains(friend.id) ? Theme.neonPurple : Theme.textSecondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .overlay {
                if appState.friends.isEmpty {
                    ContentUnavailableView {
                        Label("chat.noFriends.title", systemImage: "person.2.slash")
                    } description: {
                        Text("chat.noFriends.body")
                    }
                }
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                if allowsMultiple {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") {
                            let picked = appState.friends.filter { selected.contains($0.id) }
                            dismiss()
                            onPick(picked)
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
    }
}

struct CreateGroupChatSheet: View {
    static let emojis = ["⚡", "🎉", "🍕", "🍸", "🎶", "🏖️", "⚽", "🌙", "🔥", "💜", "🚀", "🎮"]

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onCreated: (UUID) -> Void

    @State private var name = ""
    @State private var emoji = "⚡"
    @State private var selected: Set<UUID> = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty && !isCreating
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(verbatim: emoji)
                        .font(.system(size: 54))
                        .frame(width: 96, height: 96)
                        .glassCircle()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.emojis, id: \.self) { item in
                                Button {
                                    HapticManager.shared.selection()
                                    withAnimation(Theme.spring) { emoji = item }
                                } label: {
                                    Text(verbatim: item)
                                        .font(.system(size: 26))
                                        .frame(width: 46, height: 46)
                                        .background {
                                            Circle().fill(emoji == item ? Theme.neonPurple.opacity(0.3) : Theme.surface.opacity(Theme.surfaceOpacity))
                                        }
                                }
                                .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    TextField("chat.group.name", text: $name)
                        .font(Theme.text(.body, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($isNameFocused)
                        .padding(14)
                        .glassCard(cornerRadius: Theme.Radius.control)
                        .padding(.horizontal, 20)
                        .onChange(of: name) { _, value in
                            if value.count > 40 { name = String(value.prefix(40)) }
                        }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("chat.group.members \(selected.count)")
                            .font(Theme.text(.footnote, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 24)
                        VStack(spacing: 0) {
                            ForEach(appState.friends) { friend in
                                Button {
                                    HapticManager.shared.selection()
                                    if selected.contains(friend.id) { selected.remove(friend.id) } else { selected.insert(friend.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        AvatarBadge(user: friend, size: 38)
                                        Text(verbatim: friend.displayName)
                                            .font(Theme.text(.subheadline, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                        Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(selected.contains(friend.id) ? Theme.neonPurple : Theme.textSecondary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .glassCard(cornerRadius: Theme.Radius.card)
                        .padding(.horizontal, 20)
                    }

                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(Theme.text(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    Button {
                        create()
                    } label: {
                        HStack(spacing: 8) {
                            if isCreating {
                                ProgressView().tint(Color.white)
                            } else {
                                Image(systemName: "person.3.fill")
                            }
                            Text("chat.group.create")
                        }
                    }
                    .buttonStyle(PrimaryGradientButtonStyle())
                    .disabled(!canCreate)
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.obsidian.ignoresSafeArea())
            .navigationTitle(Text("chat.new.group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        let members = appState.friends.filter { selected.contains($0.id) }
        let title = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let id = try await appState.social.createGroup(title: title, emoji: emoji, members: members, isDemo: members.contains { appState.isDemoFriend($0.id) })
                HapticManager.shared.success()
                dismiss()
                onCreated(id)
            } catch {
                HapticManager.shared.error()
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

// MARK: - Conversation

struct ChatRoomView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationService.self) private var locationService

    let threadID: UUID

    @State private var draft = ""
    @State private var reactingTo: UUID?
    @State private var isCameraPresented = false
    @State private var isSending = false
    @State private var burst: UUID?
    @State private var recorder = VoiceRecorder()
    @State private var isThemePickerPresented = false
    @State private var deleting: ChatMessage?
    @FocusState private var isInputFocused: Bool

    private var social: SocialStore { appState.social }
    private var me: UUID { appState.currentUser.id }
    private var thread: ChatThread? { social.thread(threadID) }
    private var messages: [ChatMessage] { social.messages[threadID] ?? [] }
    private var theme: ChatTheme { ChatTheme.named(thread?.theme) }
    private var readStates: [UUID: Date] { social.readStates[threadID] ?? [:] }

    /// The others who have read up to this message.
    private func seenBy(_ message: ChatMessage) -> [UserProfile] {
        others.filter { person in
            guard let read = readStates[person.id] else { return false }
            return read >= message.sentAt
        }
    }

    private func tickStatus(_ message: ChatMessage) -> MessageTicks.Status {
        if social.pendingMessageIDs.contains(message.id) || message.attachmentBucket == "local" { return .sending }
        let seen = seenBy(message)
        return !others.isEmpty && seen.count == others.count ? .seen : .sent
    }

    private var lastOwnMessageID: UUID? {
        messages.last { $0.senderID == me && $0.kind != .theme }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if let thread, thread.isEphemeral, let expiry = thread.expiresAt {
                            Label {
                                Text("chat.ephemeral.note \(LocaleFormatter.remaining(until: expiry))")
                            } icon: {
                                Image(systemName: "timer")
                            }
                            .font(Theme.rounded(.caption, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassCapsule()
                            .padding(.vertical, 8)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let previous = index > 0 ? messages[index - 1] : nil
                            bubbleRow(message, previous: previous)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.count) { _, _ in
                    withAnimation(Theme.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onTapGesture {
                    if reactingTo != nil || deleting != nil {
                        withAnimation(Theme.spring) {
                            reactingTo = nil
                            deleting = nil
                        }
                    }
                }
            }
            inputBar
        }
        .background(theme.backgroundView.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                header
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    HapticManager.shared.tap()
                    isThemePickerPresented = true
                } label: {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
                .accessibilityLabel(Text("chat.theme.title"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let point = focusPoint {
                    Button {
                        HapticManager.shared.tap()
                        social.isChatListPresented = false
                        appState.showOnMap(point)
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .accessibilityLabel(Text("chat.centerOnMap"))
                }
            }
        }
        .task {
            await social.loadMessages(threadID: threadID)
            await social.markRead(threadID: threadID)
            await social.loadReadStates(threadID: threadID)
            // Light polling while the conversation is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await social.loadMessages(threadID: threadID)
                await social.loadReadStates(threadID: threadID)
                if (social.thread(threadID)?.unreadCount ?? 0) > 0 || messages.last?.senderID != me {
                    await social.markRead(threadID: threadID)
                }
            }
        }
        .sheet(isPresented: $isCameraPresented) {
            ChatCameraPicker { image in
                sendPhoto(image)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isThemePickerPresented) {
            ChatThemePickerSheet(threadID: threadID)
        }
        .onDisappear {
            if recorder.isRecording { recorder.cancel() }
            VoicePlayer.shared.stop()
        }
    }

    // MARK: Header

    private var others: [UserProfile] {
        thread?.others(excluding: me) ?? []
    }

    private var isActive: Bool {
        others.contains { appState.isActiveOnMap($0.id) }
    }

    private var focusPoint: GeoPoint? {
        for person in others {
            if let point = appState.mapPoint(for: person.id) { return point }
        }
        return nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            ThreadAvatar(people: others, emoji: thread?.type == .direct ? "" : (thread?.emoji ?? ""), size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: thread?.displayTitle(for: me) ?? "")
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if isActive {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.emerald).frame(width: 6, height: 6)
                        Text("chat.activeOnMap")
                    }
                    .font(Theme.rounded(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.emerald)
                } else if let thread, thread.type != .direct {
                    Text("chat.members \(thread.participants.count)")
                        .font(Theme.rounded(.caption2, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: Bubbles

    @ViewBuilder
    private func bubbleRow(_ message: ChatMessage, previous: ChatMessage?) -> some View {
        if case let .themeChange(themeID) = message.content {
            themeChangeRow(message, themeID: themeID)
        } else {
            messageRow(message, previous: previous)
        }
    }

    private func themeChangeRow(_ message: ChatMessage, themeID: String) -> some View {
        let chosen = ChatTheme.named(themeID)
        let label = "\(chosen.emoji) \(chosen.name)"
        let who = thread?.participants.first { $0.id == message.senderID }?.firstName ?? ""
        return Text(message.senderID == me ? String(localized: "chat.theme.changed.you \(label)") : String(localized: "chat.theme.changed \(who) \(label)"))
            .font(Theme.rounded(.caption, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, previous: ChatMessage?) -> some View {
        let isMine = message.senderID == me
        let showsSender = !isMine && thread?.type != .direct && previous?.senderID != message.senderID
        let sender = thread?.participants.first { $0.id == message.senderID }
        let gap = previous.map { message.sentAt.timeIntervalSince($0.sentAt) > 20 * 60 } ?? true

        VStack(spacing: 4) {
            if gap {
                Text(verbatim: message.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.rounded(.caption2, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.vertical, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if isMine { Spacer(minLength: 48) }
                if !isMine, thread?.type != .direct {
                    if previous?.senderID != message.senderID || gap, let sender {
                        AvatarBadge(user: sender, size: 28)
                    } else {
                        Color.clear.frame(width: 28, height: 28)
                    }
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                    if showsSender, let sender {
                        Text(verbatim: sender.firstName)
                            .font(Theme.rounded(.caption2, weight: .bold))
                            .foregroundStyle(Color(hexString: sender.avatarColorHex))
                            .padding(.horizontal, 6)
                    }
                    bubble(message, isMine: isMine)
                        .overlay(alignment: isMine ? .topTrailing : .topLeading) {
                            if reactingTo == message.id {
                                reactionPicker(for: message)
                                    .offset(y: -50)
                                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                                    .zIndex(2)
                            } else if deleting?.id == message.id {
                                deleteConfirm(for: message)
                                    .offset(y: -50)
                                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                                    .zIndex(2)
                            }
                        }
                        .overlay {
                            if burst == message.id {
                                Text(verbatim: "❤️")
                                    .font(.system(size: 54))
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            }
                        }
                        .onTapGesture(count: 2) {
                            doubleTap(message)
                        }
                        .onLongPressGesture(minimumDuration: 0.35) {
                            HapticManager.shared.selection()
                            withAnimation(Theme.spring) { reactingTo = message.id }
                        }
                    reactionChips(message, isMine: isMine)
                    if isMine {
                        receipt(message)
                    }
                }
                if !isMine { Spacer(minLength: 48) }
            }
        }
        .zIndex(reactingTo == message.id || deleting?.id == message.id ? 1 : 0)
    }

    /// ✓ / ✓✓ under your messages; "Seen" (or who saw it) under the last one.
    @ViewBuilder
    private func receipt(_ message: ChatMessage) -> some View {
        let status = tickStatus(message)
        let isLast = message.id == lastOwnMessageID
        HStack(spacing: 4) {
            if isLast {
                let seen = seenBy(message)
                Group {
                    if status == .sending {
                        Text("chat.sending")
                    } else if thread?.type == .direct || others.count <= 1 {
                        Text(seen.isEmpty ? LocalizedStringKey("chat.sent") : LocalizedStringKey("chat.seen"))
                    } else if seen.isEmpty {
                        Text("chat.sent")
                    } else if seen.count == others.count {
                        Text("chat.seenByAll")
                    } else {
                        Text("chat.seenBy \(seen.map(\.firstName).joined(separator: ", "))")
                    }
                }
                .font(Theme.rounded(.caption2, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            }
            MessageTicks(state: status, tint: theme.accent, secondary: theme.secondaryText)
        }
        .padding(.horizontal, 6)
        .padding(.top, -2)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage, isMine: Bool) -> some View {
        switch message.content {
        case let .text(text):
            textBubble(text, isMine: isMine)
        case let .livePhoto(key, caption):
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                attachmentImage(key: key, width: 220, height: 290)
                if let caption {
                    textBubble(caption, isMine: isMine)
                }
            }
        case let .pinReply(refID, key, place, text, isStory):
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Button {
                    openReference(refID: refID, isStory: isStory)
                } label: {
                    HStack(spacing: 10) {
                        if let key {
                            attachmentImage(key: key, width: 48, height: 64, cornerRadius: 10)
                        } else {
                            Image(systemName: isStory ? "circle.dashed" : "mappin.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(isStory ? AnyShapeStyle(StoryRingStyle.linear) : AnyShapeStyle(Theme.emerald))
                                .frame(width: 48, height: 64)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isStory ? LocalizedStringKey("chat.reply.story") : LocalizedStringKey("chat.reply.pin"))
                                .font(Theme.rounded(.caption, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                            if !place.isEmpty {
                                Label {
                                    Text(verbatim: place)
                                } icon: {
                                    Image(systemName: "mappin")
                                }
                                .font(Theme.rounded(.caption, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(width: 220)
                    .glassCard(cornerRadius: 16)
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
                if !text.isEmpty {
                    textBubble(text, isMine: isMine)
                }
            }
        case let .locationPing(latitude, longitude, place, eta):
            locationBubble(latitude: latitude, longitude: longitude, place: place, eta: eta, isMine: isMine)
        case let .voice(key, durationMs, levels):
            VoiceBubble(message: message, key: key, durationMs: durationMs, levels: levels, isMine: isMine, theme: theme)
        case .themeChange:
            EmptyView()
        }
    }

    private func textBubble(_ text: String, isMine: Bool) -> some View {
        Text(verbatim: text)
            .font(Theme.text(.body))
            .foregroundStyle(isMine ? Color.white : Color.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isMine {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.bubbleGradient)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(ChatStyle.receivedFill)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        }
                }
            }
            .shadow(color: isMine ? theme.accent.opacity(0.25) : Color.black.opacity(0.15), radius: 8, y: 3)
    }

    @ViewBuilder
    private func attachmentImage(key: String, width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 18) -> some View {
        Group {
            if let image = social.image(for: key) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x312E81), Color(hex: 0x1E1B4B)], startPoint: .top, endPoint: .bottom)
                    ProgressView().tint(Color.white)
                }
                .onAppear { social.loadImage(key) }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func locationBubble(latitude: Double, longitude: Double, place: String, eta: Int?, isMine: Bool) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return Button {
            HapticManager.shared.tap()
            social.isChatListPresented = false
            appState.showOnMap(GeoPoint(latitude: latitude, longitude: longitude))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600)), interactionModes: []) {
                    Annotation("", coordinate: coordinate) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.white, Theme.electricViolet)
                    }
                }
                .frame(width: 220, height: 120)
                .allowsHitTesting(false)
                HStack(spacing: 8) {
                    Image(systemName: eta != nil ? "figure.walk" : "location.fill")
                        .foregroundStyle(Theme.emerald)
                    VStack(alignment: .leading, spacing: 1) {
                        if let eta {
                            Text("chat.location.eta \(eta)")
                                .font(Theme.text(.subheadline, weight: .bold))
                        } else {
                            Text("chat.location.here")
                                .font(Theme.text(.subheadline, weight: .bold))
                        }
                        if !place.isEmpty {
                            Text(verbatim: place)
                                .font(Theme.text(.caption))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
            .frame(width: 220)
            .glassCard(cornerRadius: 18)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
    }

    @ViewBuilder
    private func reactionChips(_ message: ChatMessage, isMine: Bool) -> some View {
        let map = message.reactionMap
        if !map.isEmpty {
            HStack(spacing: 4) {
                ForEach(map.keys.sorted(), id: \.self) { emoji in
                    let people = map[emoji] ?? []
                    Button {
                        Task { await social.toggleReaction(emoji, on: message) }
                    } label: {
                        HStack(spacing: 2) {
                            Text(verbatim: emoji)
                            if people.count > 1 {
                                Text(verbatim: "\(people.count)")
                                    .font(Theme.rounded(.caption2, weight: .bold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                            Capsule().fill(people.contains(me) ? Theme.neonPurple.opacity(0.3) : Theme.surface.opacity(0.9))
                        }
                        .overlay { Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .offset(y: -6)
            .padding(.horizontal, 6)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// "Delete for everyone", right above the message (cancel by tapping anywhere else).
    private func deleteConfirm(for message: ChatMessage) -> some View {
        HStack(spacing: 4) {
            Button {
                HapticManager.shared.selection()
                withAnimation(Theme.spring) { deleting = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.85))
            .accessibilityLabel(Text("common.cancel"))
            Button {
                HapticManager.shared.tap()
                deleteForEveryone(message)
            } label: {
                Label("chat.delete.everyone", systemImage: "trash.fill")
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Capsule().fill(Theme.danger))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.92))
        }
        .padding(4)
        .glassCapsule()
        .fixedSize()
    }

    private func reactionPicker(for message: ChatMessage) -> some View {
        HStack(spacing: 6) {
            ForEach(ChatStyle.quickReactions, id: \.self) { emoji in
                Button {
                    withAnimation(Theme.spring) { reactingTo = nil }
                    Task { await social.toggleReaction(emoji, on: message) }
                } label: {
                    Text(verbatim: emoji)
                        .font(.system(size: 26))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.8))
            }
            if message.senderID == me, !social.pendingMessageIDs.contains(message.id) {
                Divider().frame(height: 26)
                Button {
                    HapticManager.shared.selection()
                    withAnimation(Theme.spring) {
                        reactingTo = nil
                        deleting = message
                    }
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.8))
                .accessibilityLabel(Text("chat.delete.everyone"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .glassCapsule()
        .fixedSize()
    }

    // MARK: Input

    @ViewBuilder
    private var inputBar: some View {
        if recorder.isRecording {
            recordingBar
        } else {
            composeBar
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 42, height: 42)
                    .glassCircle()
            }
            .accessibilityLabel(Text("chat.voice.cancel"))
            HStack(spacing: 8) {
                Circle().fill(Theme.danger).frame(width: 9, height: 9)
                    .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.35)
                Text(verbatim: VoiceFormat.clock(recorder.elapsed))
                    .font(Theme.rounded(.subheadline, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                WaveformBars(levels: Array(recorder.levels.suffix(36)), progress: 1, filled: theme.accent, empty: theme.accent)
                    .frame(height: 24)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 42)
            .glassCard(cornerRadius: 21)
            Button {
                sendVoice()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(theme.bubbleGradient, in: Circle())
            }
            .accessibilityLabel(Text("chat.send"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var composeBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                HapticManager.shared.tap()
                isCameraPresented = true
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(Theme.accentGradient, in: Circle())
            }
            .accessibilityLabel(Text("chat.camera"))

            Menu {
                Button {
                    sendLocation(eta: nil)
                } label: {
                    Label("chat.location.send", systemImage: "location.fill")
                }
                ForEach([5, 10, 15, 30], id: \.self) { minutes in
                    Button {
                        sendLocation(eta: minutes)
                    } label: {
                        Label("chat.location.eta \(minutes)", systemImage: "figure.walk")
                    }
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.emerald)
                    .frame(width: 42, height: 42)
                    .glassCircle()
            }
            .accessibilityLabel(Text("chat.location.send"))

            HStack(alignment: .bottom, spacing: 6) {
                TextField("chat.input.placeholder", text: $draft, axis: .vertical)
                    .font(Theme.text(.body))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.vertical, 10)
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        sendText()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Theme.accentGradient, in: Circle())
                    }
                    .padding(.bottom, 5)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(Text("chat.send"))
                } else {
                    Button {
                        startVoice()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 32, height: 32)
                    }
                    .padding(.bottom, 5)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(Text("chat.voice.record"))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .frame(minHeight: 42)
            .glassCard(cornerRadius: 21)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(Theme.spring, value: draft.isEmpty)
    }

    // MARK: Actions

    private func doubleTap(_ message: ChatMessage) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { burst = message.id }
        Task {
            await social.toggleReaction("❤️", on: message)
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) {
                if burst == message.id { burst = nil }
            }
        }
    }

    private func openReference(refID: UUID?, isStory: Bool) {
        HapticManager.shared.tap()
        if isStory {
            if let refID, let ring = social.storyRings.first(where: { ring in ring.stories.contains { $0.id == refID } }) {
                social.isChatListPresented = false
                social.storyViewerStart = ring.author.id
            } else if refID != nil {
                appState.showToast(.info, title: String(localized: "chat.reply.storyExpired"))
            }
            return
        }
        guard let refID else { return }
        if appState.pins.contains(where: { $0.id == refID }) {
            social.isChatListPresented = false
            appState.requestFocus(on: refID, openViewer: true)
        } else {
            appState.showToast(.info, title: String(localized: "chat.reply.pinExpired"))
        }
    }

    private func startVoice() {
        VoicePlayer.shared.stop()
        isInputFocused = false
        recorder.onLimit = { sendVoice() }
        Task {
            let ok = await recorder.start()
            if !ok {
                appState.showToast(.warning, title: String(localized: "chat.voice.micDenied"))
            }
        }
    }

    private func sendVoice() {
        guard let result = recorder.finish() else { return }
        HapticManager.shared.success()
        var outgoing = OutgoingMessage(kind: .voice)
        outgoing.voice = result.data
        outgoing.durationMs = result.durationMs
        outgoing.waveform = result.waveform
        send(outgoing)
    }

    private func deleteForEveryone(_ message: ChatMessage) {
        deleting = nil
        if VoicePlayer.shared.currentID == message.id { VoicePlayer.shared.stop() }
        Task {
            do {
                try await social.deleteForEveryone(message)
            } catch {
                appState.showToast(.warning, title: String(localized: "chat.delete.failed"), subtitle: error.localizedDescription)
            }
        }
    }

    private func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(OutgoingMessage(kind: .text, body: text))
    }

    private func sendPhoto(_ image: UIImage) {
        Task {
            guard let data = await Self.compress(image) else { return }
            var outgoing = OutgoingMessage(kind: .photo)
            outgoing.photo = data
            send(outgoing)
        }
    }

    /// 3:4 JPEG like the other photos, encoded off the main thread.
    nonisolated private static func compress(_ image: UIImage) async -> Data? {
        let resized = ImageCompressor.cropAndResize(image, aspect: ImageCompressor.portraitAspect, longEdge: ImageCompressor.fullLongEdge)
        return resized.jpegData(compressionQuality: ImageCompressor.fullQuality)
    }

    private func sendLocation(eta: Int?) {
        HapticManager.shared.tap()
        Task {
            var point = appState.userLocation ?? locationService.lastFix
            if point == nil, locationService.isAuthorized {
                point = await locationService.currentLocation(maximumAge: 60)
            }
            guard let point else {
                appState.showToast(.warning, title: String(localized: "chat.location.unavailable"))
                return
            }
            let place = await locationService.placeName(for: point) ?? ""
            var outgoing = OutgoingMessage(kind: .location)
            outgoing.latitude = point.latitude
            outgoing.longitude = point.longitude
            outgoing.placeName = place
            outgoing.etaMinutes = eta
            send(outgoing)
        }
    }

    private func send(_ outgoing: OutgoingMessage) {
        Task {
            do {
                try await social.send(outgoing, to: threadID)
            } catch {
                appState.showToast(.warning, title: String(localized: "chat.send.failed"), subtitle: error.localizedDescription)
            }
        }
    }
}

// MARK: - Camera

/// The system camera for chat photos (photo library on devices without a camera).
struct ChatCameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        if picker.sourceType == .camera {
            picker.cameraDevice = .rear
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ChatCameraPicker

        init(parent: ChatCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
