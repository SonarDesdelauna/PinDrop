import Observation
import SwiftUI
import UIKit

/// Chats and 24 h stories: loading, sending, read state and the demo content.
@MainActor
@Observable
final class SocialStore {
    private(set) var threads: [ChatThread] = []
    private(set) var messages: [UUID: [ChatMessage]] = [:]
    private(set) var storyRings: [UserStoryRing] = []
    private(set) var myStories: [StoryItem] = []
    /// Downloaded images keyed by "bucket/path".
    private(set) var images: [String: Data] = [:]
    private(set) var isPublishingStory = false

    /// The chat list sheet, and the conversation to open in it.
    var isChatListPresented = false
    var openThreadID: UUID?
    /// The story viewer: which person to start from.
    var storyViewerStart: UUID?
    /// The camera was opened from "Your story": preselect Story.
    var prefersStoryCapture = false

    @ObservationIgnored private let dataService: SupabaseDataService
    @ObservationIgnored private var imageLoads: Set<String> = []
    @ObservationIgnored private var failedImages: Set<String> = []
    @ObservationIgnored private var demoThreads: [ChatThread] = []
    @ObservationIgnored private var demoMessages: [UUID: [ChatMessage]] = [:]
    @ObservationIgnored private var demoRings: [UserStoryRing] = []
    @ObservationIgnored private var serverThreads: [ChatThread] = []
    @ObservationIgnored private var serverStories: [StoryItem] = []
    @ObservationIgnored private(set) var userID: UUID?
    @ObservationIgnored private var currentUserProfile: UserProfile?

    init(dataService: SupabaseDataService) {
        self.dataService = dataService
    }

    // MARK: - Derived

    var totalUnread: Int {
        threads.reduce(0) { $0 + $1.unreadCount }
    }

    func thread(_ id: UUID) -> ChatThread? {
        threads.first { $0.id == id }
    }

    func isDemoThread(_ id: UUID) -> Bool {
        demoThreads.contains { $0.id == id }
    }

    func image(for key: String?) -> UIImage? {
        guard let key, let data = images[key] else { return nil }
        return ImageCache.image(forKey: key, data: data)
    }

    /// The 1-to-1 chat with a friend, if it already exists.
    func directThread(with friendID: UUID) -> ChatThread? {
        threads.first { $0.type == .direct && $0.participants.contains { $0.id == friendID } }
    }

    // MARK: - Session

    func reset() {
        threads = []
        messages = [:]
        storyRings = []
        myStories = []
        images = [:]
        serverThreads = []
        serverStories = []
        demoThreads = []
        demoMessages = [:]
        demoRings = []
        userID = nil
        isChatListPresented = false
        openThreadID = nil
        storyViewerStart = nil
    }

    func refresh(userID: UUID) async {
        self.userID = userID
        async let threadsLoad = try? dataService.fetchChatThreads()
        async let storiesLoad = try? dataService.fetchStories()
        let (loadedThreads, loadedStories) = await (threadsLoad, storiesLoad)
        if let loadedThreads {
            serverThreads = loadedThreads
        }
        if let loadedStories {
            serverStories = loadedStories
        }
        rebuild()
    }

    private func rebuild() {
        guard let userID else { return }
        let merged = (serverThreads + demoThreads).sorted { $0.lastActivity > $1.lastActivity }
        if merged != threads {
            withAnimation(Theme.spring) { threads = merged }
        }

        let now = Date.now
        var live = serverStories.filter { !$0.isExpired(at: now) }
        for index in live.indices {
            live[index].viewedByMe = live[index].views.contains { $0.viewerID == userID } || live[index].author.id == userID
            live[index].likedByMe = live[index].views.contains { $0.viewerID == userID && $0.liked }
        }
        let mine = live.filter { $0.author.id == userID }
        var grouped: [UUID: [StoryItem]] = [:]
        var authors: [UUID: UserProfile] = [:]
        for story in live where story.author.id != userID {
            grouped[story.author.id, default: []].append(story)
            authors[story.author.id] = story.author
        }
        var rings = grouped.compactMap { id, stories -> UserStoryRing? in
            guard let author = authors[id] else { return nil }
            return UserStoryRing(author: author, stories: stories.sorted { $0.createdAt < $1.createdAt })
        }
        rings.append(contentsOf: demoRings)
        // Unseen first, then the most recent.
        rings.sort { lhs, rhs in
            if lhs.hasUnseenStories != rhs.hasUnseenStories { return lhs.hasUnseenStories }
            return (lhs.stories.last?.createdAt ?? .distantPast) > (rhs.stories.last?.createdAt ?? .distantPast)
        }
        if rings != storyRings {
            withAnimation(Theme.spring) { storyRings = rings }
        }
        if mine != myStories {
            myStories = mine
        }
        for ring in rings {
            for story in ring.stories {
                loadImage(story.imageKey)
            }
        }
        for story in mine {
            loadImage(story.imageKey)
        }
    }

    // MARK: - Images

    func loadImage(_ key: String?) {
        guard let key, images[key] == nil, !imageLoads.contains(key), !failedImages.contains(key) else { return }
        imageLoads.insert(key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.imageLoads.remove(key) }
            do {
                let data = try await self.dataService.loadImage(key: key)
                self.images[key] = data
            } catch {
                self.failedImages.insert(key)
            }
        }
    }

    func storeImage(_ data: Data, for key: String) {
        images[key] = data
    }

    // MARK: - Chats

    func loadMessages(threadID: UUID) async {
        if isDemoThread(threadID) {
            messages[threadID] = demoMessages[threadID] ?? []
            return
        }
        guard let loaded = try? await dataService.fetchMessages(threadID: threadID) else { return }
        if loaded != messages[threadID] {
            withAnimation(Theme.spring) { messages[threadID] = loaded }
        }
        for message in loaded {
            loadImage(message.attachmentKey)
        }
    }

    func markRead(threadID: UUID) async {
        if let index = threads.firstIndex(where: { $0.id == threadID }), threads[index].unreadCount > 0 {
            threads[index].unreadCount = 0
        }
        if let index = serverThreads.firstIndex(where: { $0.id == threadID }) {
            serverThreads[index].unreadCount = 0
        }
        if let index = demoThreads.firstIndex(where: { $0.id == threadID }) {
            demoThreads[index].unreadCount = 0
            return
        }
        try? await dataService.markChatRead(threadID: threadID)
    }

    /// Opens (or creates) the chat with a friend. Returns the thread id.
    func openDirectChat(with friend: UserProfile, isDemo: Bool = false) async throws -> UUID {
        if let existing = directThread(with: friend.id) {
            return existing.id
        }
        if isDemo {
            return makeDemoThread(type: .direct, title: nil, emoji: "", members: [friend], ephemeralHours: 0)
        }
        let id = try await dataService.openDirectChat(with: friend.id)
        if let userID { await refresh(userID: userID) }
        return id
    }

    func createGroup(title: String, emoji: String, members: [UserProfile], ephemeralHours: Int = 0, isDemo: Bool = false) async throws -> UUID {
        // A hub chat with the same people is reused while it is still alive.
        if ephemeralHours > 0, let userID {
            let wanted = Set(members.map(\.id)).union([userID])
            if let existing = threads.first(where: { $0.type == .clusterLive && Set($0.participants.map(\.id)) == wanted && ($0.expiresAt ?? .distantFuture) > .now }) {
                return existing.id
            }
        }
        if isDemo {
            return makeDemoThread(type: ephemeralHours > 0 ? .clusterLive : .group, title: title, emoji: emoji, members: members, ephemeralHours: ephemeralHours)
        }
        let id = try await dataService.createGroupChat(
            title: title,
            emoji: emoji,
            memberIDs: members.map(\.id),
            ephemeralHours: ephemeralHours
        )
        if let userID { await refresh(userID: userID) }
        return id
    }

    /// A local conversation with demo friends (they are not real accounts).
    private func makeDemoThread(type: ChatThread.ThreadType, title: String?, emoji: String, members: [UserProfile], ephemeralHours: Int) -> UUID {
        let me = currentUserProfile ?? members.first
        var participants = members
        if let me, !participants.contains(where: { $0.id == me.id }) {
            participants.insert(me, at: 0)
        }
        let thread = ChatThread(
            id: UUID(),
            type: type,
            title: title,
            emoji: emoji,
            participants: participants,
            lastMessage: nil,
            unreadCount: 0,
            createdAt: .now,
            expiresAt: ephemeralHours > 0 ? Date.now.addingTimeInterval(Double(ephemeralHours) * 3_600) : nil
        )
        demoThreads.append(thread)
        demoMessages[thread.id] = []
        rebuild()
        return thread.id
    }

    func leave(threadID: UUID) async {
        if isDemoThread(threadID) {
            demoThreads.removeAll { $0.id == threadID }
        } else {
            try? await dataService.leaveChat(threadID: threadID)
            serverThreads.removeAll { $0.id == threadID }
        }
        rebuild()
    }

    /// Sends a message; it appears right away and is confirmed by the server.
    func send(_ outgoing: OutgoingMessage, to threadID: UUID) async throws {
        guard let userID else { return }
        HapticManager.shared.tap()
        let local = ChatMessage(
            threadID: threadID,
            senderID: userID,
            kind: outgoing.kind,
            body: outgoing.body,
            attachmentBucket: outgoing.photo != nil ? "local" : outgoing.attachmentBucket,
            attachmentPath: outgoing.photo != nil ? UUID().uuidString : outgoing.attachmentPath,
            refID: outgoing.refID,
            placeName: outgoing.placeName,
            latitude: outgoing.latitude,
            longitude: outgoing.longitude,
            etaMinutes: outgoing.etaMinutes
        )
        if let photo = outgoing.photo, let key = local.attachmentKey {
            images[key] = photo
        }
        withAnimation(Theme.spring) {
            messages[threadID, default: []].append(local)
        }
        updatePreview(threadID: threadID, with: local)

        if isDemoThread(threadID) {
            demoMessages[threadID, default: []].append(local)
            scheduleDemoReply(in: threadID)
            return
        }
        do {
            let saved = try await dataService.sendMessage(outgoing, to: threadID)
            if let photo = outgoing.photo, let key = saved.attachmentKey {
                images[key] = photo
            }
            if var list = messages[threadID], let index = list.firstIndex(where: { $0.id == local.id }) {
                list[index] = saved
                messages[threadID] = list
            }
            updatePreview(threadID: threadID, with: saved)
        } catch {
            messages[threadID]?.removeAll { $0.id == local.id }
            HapticManager.shared.error()
            throw error
        }
    }

    private func updatePreview(threadID: UUID, with message: ChatMessage) {
        if let index = serverThreads.firstIndex(where: { $0.id == threadID }) {
            serverThreads[index].lastMessage = message
        }
        if let index = demoThreads.firstIndex(where: { $0.id == threadID }) {
            demoThreads[index].lastMessage = message
        }
        rebuild()
    }

    /// Double tap reactions: adds the emoji, or removes it if you had already used it.
    func toggleReaction(_ emoji: String, on message: ChatMessage) async {
        guard let userID else { return }
        HapticManager.shared.reaction()
        let had = message.reactions.contains { $0.userID == userID && $0.emoji == emoji }
        var updated = message
        if had {
            updated.reactions.removeAll { $0.userID == userID && $0.emoji == emoji }
        } else {
            updated.reactions.append(ChatReaction(userID: userID, emoji: emoji))
        }
        replace(updated)
        if isDemoThread(message.threadID) {
            if let index = demoMessages[message.threadID]?.firstIndex(where: { $0.id == message.id }) {
                demoMessages[message.threadID]?[index] = updated
            }
            return
        }
        do {
            try await dataService.setChatReaction(emoji, on: message.id, add: !had)
        } catch {
            replace(message)
        }
    }

    private func replace(_ message: ChatMessage) {
        guard var list = messages[message.threadID], let index = list.firstIndex(where: { $0.id == message.id }) else { return }
        list[index] = message
        withAnimation(Theme.spring) { messages[message.threadID] = list }
    }

    // MARK: - Stories

    func publishStory(photo: Data, video: URL? = nil, overlayText: String, overlayY: Double, locationTag: String?) async throws {
        isPublishingStory = true
        defer { isPublishingStory = false }
        let story = try await dataService.publishStory(photo: photo, video: video, overlayText: overlayText, overlayY: overlayY, locationTag: locationTag)
        images[story.imageKey] = photo
        if let video, let key = story.videoKey {
            dataService.cacheVideo(video, key: key)
        }
        serverStories.append(story)
        rebuild()
    }

    func deleteStory(_ story: StoryItem) async {
        try? await dataService.deleteStory(story)
        serverStories.removeAll { $0.id == story.id }
        rebuild()
    }

    func markViewed(_ story: StoryItem) {
        guard let userID, story.author.id != userID, !story.viewedByMe else { return }
        setViewState(story, viewed: true, liked: story.likedByMe)
        guard !isDemoRingStory(story) else { return }
        Task { try? await dataService.markStoryViewed(story.id, liked: story.likedByMe) }
    }

    func toggleLike(_ story: StoryItem) {
        guard let userID, story.author.id != userID else { return }
        let liked = !story.likedByMe
        if liked {
            HapticManager.shared.reaction()
        } else {
            HapticManager.shared.selection()
        }
        setViewState(story, viewed: true, liked: liked)
        guard !isDemoRingStory(story) else { return }
        Task { try? await dataService.markStoryViewed(story.id, liked: liked) }
    }

    private func isDemoRingStory(_ story: StoryItem) -> Bool {
        demoRings.contains { ring in ring.stories.contains { $0.id == story.id } }
    }

    private func setViewState(_ story: StoryItem, viewed: Bool, liked: Bool) {
        guard let userID else { return }
        if let index = serverStories.firstIndex(where: { $0.id == story.id }) {
            serverStories[index].views.removeAll { $0.viewerID == userID }
            serverStories[index].views.append(StoryView(viewerID: userID, liked: liked, viewedAt: .now, viewer: nil))
        }
        for ringIndex in demoRings.indices {
            if let storyIndex = demoRings[ringIndex].stories.firstIndex(where: { $0.id == story.id }) {
                demoRings[ringIndex].stories[storyIndex].viewedByMe = viewed
                demoRings[ringIndex].stories[storyIndex].likedByMe = liked
            }
        }
        rebuild()
    }

    /// Replies to a story in the 1-to-1 chat with its author.
    func replyToStory(_ story: StoryItem, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let threadID: UUID
        if let existing = directThread(with: story.author.id) {
            threadID = existing.id
        } else {
            threadID = try await openDirectChat(with: story.author, isDemo: isDemoRingStory(story))
        }
        let parts = story.imageKey.split(separator: "/", maxSplits: 1).map(String.init)
        var outgoing = OutgoingMessage(kind: .storyReply, body: trimmed)
        outgoing.attachmentBucket = parts.count == 2 ? parts[0] : nil
        outgoing.attachmentPath = parts.count == 2 ? parts[1] : nil
        outgoing.refID = story.id
        outgoing.placeName = story.locationTag ?? ""
        try await send(outgoing, to: threadID)
    }

    // MARK: - Demo

    var hasDemo: Bool { !demoThreads.isEmpty || !demoRings.isEmpty }

    /// Three realistic conversations and four story rings, local only.
    func installDemo(currentUser: UserProfile) {
        if userID == nil { userID = currentUser.id }
        currentUserProfile = currentUser
        let me = currentUser
        let marco = MockDataService.marco
        let giulia = MockDataService.giulia
        let alex = MockDataService.alex
        let sofia = MockDataService.profile(id: MockDataService.extraFriendIDs[0], name: "Sofia Bianchi", username: "sofia.demo", colorHex: "#EC4899", emoji: "✨")
        let now = Date.now

        let giuliaThread = UUID(uuidString: "D3E0C001-0000-4000-8000-00000000C001") ?? UUID()
        let marcoThread = UUID(uuidString: "D3E0C001-0000-4000-8000-00000000C002") ?? UUID()
        let crewThread = UUID(uuidString: "D3E0C001-0000-4000-8000-00000000C003") ?? UUID()

        func message(_ thread: UUID, _ sender: UserProfile, _ minutesAgo: Double, _ kind: ChatMessage.Kind, _ body: String,
                     place: String? = nil, reactions: [ChatReaction] = [], lat: Double? = nil, lon: Double? = nil, eta: Int? = nil) -> ChatMessage {
            ChatMessage(
                threadID: thread,
                senderID: sender.id,
                kind: kind,
                body: body,
                placeName: place,
                latitude: lat,
                longitude: lon,
                etaMinutes: eta,
                sentAt: now.addingTimeInterval(-minutesAgo * 60),
                reactions: reactions
            )
        }

        let giuliaMessages = [
            message(giuliaThread, giulia, 42, .text, String(localized: "demo.chat.giulia.1")),
            message(giuliaThread, me, 40, .text, String(localized: "demo.chat.me.1"), reactions: [ChatReaction(userID: giulia.id, emoji: "❤️")]),
            message(giuliaThread, giulia, 12, .pinReply, String(localized: "demo.chat.giulia.2"), place: "Navigli"),
            message(giuliaThread, giulia, 3, .location, String(localized: "demo.chat.giulia.3"), place: "Darsena", lat: 45.4520, lon: 9.1760, eta: 8)
        ]
        let marcoMessages = [
            message(marcoThread, marco, 95, .text, String(localized: "demo.chat.marco.1")),
            message(marcoThread, me, 90, .text, String(localized: "demo.chat.me.2")),
            message(marcoThread, marco, 88, .text, String(localized: "demo.chat.marco.2"), reactions: [ChatReaction(userID: me.id, emoji: "🔥")])
        ]
        let crewMessages = [
            message(crewThread, alex, 30, .text, String(localized: "demo.chat.crew.1")),
            message(crewThread, giulia, 26, .text, String(localized: "demo.chat.crew.2"), reactions: [ChatReaction(userID: marco.id, emoji: "😂"), ChatReaction(userID: alex.id, emoji: "😂")]),
            message(crewThread, marco, 20, .pinReply, String(localized: "demo.chat.crew.3"), place: "Corso Como"),
            message(crewThread, alex, 6, .text, String(localized: "demo.chat.crew.4"))
        ]
        demoMessages = [giuliaThread: giuliaMessages, marcoThread: marcoMessages, crewThread: crewMessages]
        demoThreads = [
            ChatThread(id: giuliaThread, type: .direct, title: nil, participants: [me, giulia], lastMessage: giuliaMessages.last, unreadCount: 2, createdAt: now.addingTimeInterval(-3_600)),
            ChatThread(id: marcoThread, type: .direct, title: nil, participants: [me, marco], lastMessage: marcoMessages.last, unreadCount: 0, createdAt: now.addingTimeInterval(-7_200)),
            ChatThread(id: crewThread, type: .group, title: "Tonight's Crew", emoji: "⚡", participants: [me, giulia, marco, alex], lastMessage: crewMessages.last, unreadCount: 3, createdAt: now.addingTimeInterval(-5_400))
        ]

        struct DemoStory {
            let author: UserProfile
            let emoji: String
            let title: String
            let colors: [UIColor]
            let minutesAgo: Double
            let tag: String
            let text: String
            let seen: Bool
        }
        let specs: [DemoStory] = [
            DemoStory(author: giulia, emoji: "🍸", title: "Aperitivo", colors: [.systemOrange, .systemPink], minutesAgo: 50, tag: "Navigli", text: String(localized: "demo.story.giulia.1"), seen: false),
            DemoStory(author: giulia, emoji: "🌇", title: "Sunset", colors: [.systemPink, .systemPurple], minutesAgo: 25, tag: "Darsena", text: String(localized: "demo.story.giulia.2"), seen: false),
            DemoStory(author: giulia, emoji: "🎶", title: "Live", colors: [.systemPurple, .systemIndigo], minutesAgo: 5, tag: "Navigli", text: "", seen: false),
            DemoStory(author: marco, emoji: "📸", title: "Street", colors: [.systemTeal, .systemGreen], minutesAgo: 180, tag: "Brera", text: String(localized: "demo.story.marco.1"), seen: false),
            DemoStory(author: marco, emoji: "🍕", title: "Pizza", colors: [.systemRed, .systemOrange], minutesAgo: 70, tag: "Isola", text: String(localized: "demo.story.marco.2"), seen: false),
            DemoStory(author: sofia, emoji: "🏃‍♀️", title: "Run", colors: [.systemGreen, .systemMint], minutesAgo: 400, tag: "Sempione", text: String(localized: "demo.story.sofia.1"), seen: false),
            DemoStory(author: sofia, emoji: "☕️", title: "Coffee", colors: [.brown, .systemOrange], minutesAgo: 330, tag: "Brera", text: "", seen: false),
            DemoStory(author: alex, emoji: "🎧", title: "Studio", colors: [.systemBlue, .systemIndigo], minutesAgo: 600, tag: "Porta Venezia", text: String(localized: "demo.story.alex.1"), seen: true),
            DemoStory(author: alex, emoji: "🌙", title: "Night", colors: [.systemIndigo, .black], minutesAgo: 240, tag: "Porta Venezia", text: "", seen: true)
        ]
        var rings: [UUID: UserStoryRing] = [:]
        var order: [UUID] = []
        var renderQueue: [(String, String, String, [UIColor])] = []
        for (index, spec) in specs.enumerated() {
            let key = "demo/story-\(index).jpg"
            let story = StoryItem(
                author: spec.author,
                imageKey: key,
                createdAt: now.addingTimeInterval(-spec.minutesAgo * 60),
                locationTag: spec.tag,
                overlayText: spec.text.isEmpty ? nil : spec.text,
                overlayY: index.isMultiple(of: 2) ? 0.72 : 0.3,
                viewedByMe: spec.seen
            )
            if rings[spec.author.id] == nil {
                order.append(spec.author.id)
                rings[spec.author.id] = UserStoryRing(author: spec.author, stories: [])
            }
            rings[spec.author.id]?.stories.append(story)
            renderQueue.append((key, spec.emoji, spec.title, spec.colors))
        }
        // Render the demo photos one by one without blocking the UI.
        let queue = renderQueue
        Task { [weak self] in
            for (key, emoji, title, colors) in queue {
                await Task.yield()
                guard let self, self.hasDemo else { return }
                if let data = MockDataService.renderPhoto(emoji: emoji, title: title, colors: colors)?.fullData {
                    self.storeImage(data, for: key)
                }
            }
        }
        demoRings = order.compactMap { rings[$0] }
        rebuild()
    }

    func removeDemo() {
        demoThreads = []
        demoMessages = [:]
        demoRings = []
        for key in images.keys where key.hasPrefix("demo/") {
            images[key] = nil
        }
        rebuild()
    }

    /// Demo friends answer a moment later, so the chat feels alive.
    private func scheduleDemoReply(in threadID: UUID) {
        guard let thread = demoThreads.first(where: { $0.id == threadID }),
              let userID,
              let friend = thread.others(excluding: userID).randomElement() else { return }
        let replies = [
            String(localized: "demo.chat.reply.1"),
            String(localized: "demo.chat.reply.2"),
            String(localized: "demo.chat.reply.3")
        ]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self else { return }
            let reply = ChatMessage(threadID: threadID, senderID: friend.id, kind: .text, body: replies.randomElement() ?? "👍")
            self.demoMessages[threadID, default: []].append(reply)
            withAnimation(Theme.spring) {
                self.messages[threadID, default: []].append(reply)
            }
            HapticManager.shared.selection()
            self.updatePreview(threadID: threadID, with: reply)
        }
    }
}
