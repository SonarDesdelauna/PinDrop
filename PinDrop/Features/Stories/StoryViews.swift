import SwiftUI
import UIKit

// MARK: - Shared pieces

/// The colors of a story ring (unseen) and of the story buttons.
enum StoryRingStyle {
    static let colors: [Color] = [Color(hex: 0xF59E0B), Color(hex: 0xEC4899), Color(hex: 0xA855F7), Color(hex: 0x7C3AED)]

    static var angular: AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center)
    }

    static var linear: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// The white text pill written on a story.
struct StoryTextPill: View {
    let text: String
    var isPlaceholder = false

    var body: some View {
        Text(verbatim: text)
            .font(Theme.rounded(.title3, weight: .bold))
            .foregroundStyle(isPlaceholder ? Color.white.opacity(0.6) : Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.35), radius: 10, y: 4)
    }
}

/// "📍 Navigli" sticker under the story text.
struct StoryLocationTag: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(Theme.emeraldLight)
            Text(verbatim: name)
                .lineLimit(1)
        }
        .font(Theme.rounded(.footnote, weight: .bold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// An avatar inside a story ring: animated gradient if there is something new, grey if seen.
struct StoryRingAvatar: View {
    let user: UserProfile
    let hasUnseen: Bool
    var size: CGFloat = 62

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            if hasUnseen {
                Circle()
                    .strokeBorder(StoryRingStyle.angular, lineWidth: 3)
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            } else {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.45), lineWidth: 2)
            }
            AvatarBadge(user: user, size: size - 10)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Stories bar (top of the map)

struct StoriesBarView: View {
    @Environment(AppState.self) private var appState

    private var social: SocialStore { appState.social }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                myStoryButton
                ForEach(social.storyRings) { ring in
                    Button {
                        HapticManager.shared.tap()
                        social.storyViewerStart = ring.author.id
                    } label: {
                        VStack(spacing: 4) {
                            StoryRingAvatar(user: ring.author, hasUnseen: ring.hasUnseenStories, size: 50)
                            Text(verbatim: ring.author.firstName)
                                .font(Theme.rounded(.caption2, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .frame(width: 54)
                        }
                    }
                    .buttonStyle(PressableButtonStyle(pressedScale: 0.92))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
        }
        .scrollClipDisabled()
    }

    private var myStoryButton: some View {
        let hasStory = !social.myStories.isEmpty
        return Button {
            HapticManager.shared.tap()
            if hasStory {
                social.storyViewerStart = appState.currentUser.id
            } else {
                openCamera()
            }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    if hasStory {
                        StoryRingAvatar(user: appState.currentUser, hasUnseen: true, size: 50)
                    } else {
                        AvatarBadge(user: appState.currentUser, size: 44)
                            .frame(width: 50, height: 50)
                    }
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 20, height: 20)
                        .background(Theme.accentGradient, in: Circle())
                        .overlay { Circle().strokeBorder(Theme.obsidian, lineWidth: 2) }
                        .onTapGesture {
                            HapticManager.shared.tap()
                            openCamera()
                        }
                }
                Text("story.yours")
                    .font(Theme.rounded(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 58)
            }
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.92))
        .accessibilityLabel(Text("story.yours"))
    }

    private func openCamera() {
        social.prefersStoryCapture = true
        appState.presentCamera()
    }
}

// MARK: - Full screen viewer

struct StoryViewerView: View {
    static let storyDuration: Double = 5

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let startAuthorID: UUID

    @State private var rings: [UserStoryRing] = []
    @State private var ringIndex = 0
    @State private var storyIndex = 0
    @State private var progress: Double = 0
    @State private var isHolding = false
    @State private var isPausedByUI = false
    @State private var dragOffset: CGFloat = 0
    @State private var pressStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var replyText = ""
    @State private var hearts: [HeartParticle] = []
    @State private var isViewersPresented = false
    @State private var isDeleteConfirmPresented = false
    @State private var sentReplyNotice = false
    @FocusState private var isReplyFocused: Bool

    private var social: SocialStore { appState.social }

    private var ring: UserStoryRing? {
        rings.indices.contains(ringIndex) ? rings[ringIndex] : nil
    }

    private var story: StoryItem? {
        guard let ring, ring.stories.indices.contains(storyIndex) else { return nil }
        return ring.stories[storyIndex]
    }

    private var isMine: Bool {
        ring?.author.id == appState.currentUser.id
    }

    private var isPaused: Bool {
        isHolding || isPausedByUI || isReplyFocused || isViewersPresented || isDeleteConfirmPresented
    }

    /// The current story as the store sees it now (likes and views update live).
    private var liveStory: StoryItem? {
        guard let story else { return nil }
        if isMine {
            return social.myStories.first { $0.id == story.id } ?? story
        }
        return social.storyRings.lazy.flatMap(\.stories).first { $0.id == story.id } ?? story
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if let story {
                    storyPage(story, size: proxy.size)
                        .id(story.id)
                        .transition(.opacity)
                }
            }
            .offset(y: max(0, dragOffset))
            .scaleEffect(1 - min(0.12, max(0, dragOffset) / 2_000))
            .animation(.interactiveSpring, value: dragOffset)
        }
        .statusBarHidden()
        .onAppear(perform: setUp)
        .task(id: story?.id) {
            await runTimer()
        }
        .sheet(isPresented: $isViewersPresented) {
            if let liveStory {
                StoryViewersSheet(story: liveStory)
                    .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(Text("story.delete.title"), isPresented: $isDeleteConfirmPresented, titleVisibility: .visible) {
            Button(role: .destructive) {
                deleteCurrent()
            } label: {
                Text("story.delete.confirm")
            }
        }
    }

    // MARK: Page

    private func storyPage(_ story: StoryItem, size: CGSize) -> some View {
        ZStack {
            photo(story)
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(pressGesture(width: size.width))

            if let text = story.overlayText {
                VStack(spacing: 8) {
                    StoryTextPill(text: text)
                    if let tag = story.locationTag {
                        StoryLocationTag(name: tag)
                    }
                }
                .frame(maxWidth: size.width - 40)
                .position(x: size.width / 2, y: size.height * story.overlayY)
                .allowsHitTesting(false)
                .opacity(isHolding ? 0 : 1)
            }

            VStack(spacing: 0) {
                header(story)
                Spacer()
                footer(story)
            }
            .opacity(isHolding ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: isHolding)

            ForEach(hearts) { heart in
                Image(systemName: "heart.fill")
                    .font(.system(size: heart.size))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xF43F5E), Color(hex: 0xEC4899)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color(hex: 0xF43F5E).opacity(0.6), radius: 8)
                    .offset(x: heart.x, y: heart.y)
                    .opacity(heart.opacity)
                    .position(x: size.width - 44, y: size.height - 70)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func photo(_ story: StoryItem) -> some View {
        if let image = social.image(for: story.imageKey) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1E1B4B), Color.black], startPoint: .top, endPoint: .bottom)
                ProgressView()
                    .tint(Color.white)
            }
            .onAppear { social.loadImage(story.imageKey) }
        }
    }

    private func header(_ story: StoryItem) -> some View {
        VStack(spacing: 10) {
            progressBars
            HStack(spacing: 10) {
                if let ring {
                    AvatarBadge(user: ring.author, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: isMine ? String(localized: "story.yours") : ring.author.firstName)
                            .font(Theme.rounded(.subheadline, weight: .bold))
                        HStack(spacing: 4) {
                            Text(verbatim: LocaleFormatter.relativeTimestamp(story.createdAt))
                            if let tag = story.locationTag, story.overlayText == nil {
                                Text(verbatim: "·")
                                Image(systemName: "mappin")
                                Text(verbatim: tag)
                                    .lineLimit(1)
                            }
                        }
                        .font(Theme.rounded(.caption, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    }
                    .foregroundStyle(Color.white)
                }
                Spacer()
                if isMine {
                    Button {
                        HapticManager.shared.tap()
                        isDeleteConfirmPresented = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityLabel(Text("story.delete.title"))
                }
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel(Text("common.close"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.black.opacity(0.55), Color.clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var progressBars: some View {
        HStack(spacing: 4) {
            ForEach(Array((ring?.stories ?? []).enumerated()), id: \.element.id) { index, _ in
                GeometryReader { bar in
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.white)
                                .frame(width: bar.size.width * fill(for: index))
                        }
                }
                .frame(height: 3)
            }
        }
    }

    private func fill(for index: Int) -> Double {
        if index < storyIndex { return 1 }
        if index > storyIndex { return 0 }
        return progress
    }

    @ViewBuilder
    private func footer(_ story: StoryItem) -> some View {
        if isMine {
            let viewers = (liveStory ?? story).otherViews
            Button {
                HapticManager.shared.tap()
                isViewersPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.fill")
                    Text("story.views \(viewers.count)")
                    let likes = viewers.filter(\.liked).count
                    if likes > 0 {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Color(hex: 0xF43F5E))
                        Text(verbatim: "\(likes)")
                    }
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                }
                .font(Theme.rounded(.subheadline, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
            }
            .padding(.bottom, 16)
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("", text: $replyText, prompt: Text("story.reply.placeholder \(ring?.author.firstName ?? "")").foregroundStyle(Color.white.opacity(0.7)))
                        .font(Theme.text(.subheadline))
                        .foregroundStyle(Color.white)
                        .focused($isReplyFocused)
                        .submitLabel(.send)
                        .onSubmit(sendReply)
                    if !replyText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: sendReply) {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(Color.white)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .background(Color.black.opacity(0.25), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1) }

                Button {
                    like()
                } label: {
                    Image(systemName: (liveStory?.likedByMe ?? false) ? "heart.fill" : "heart")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle((liveStory?.likedByMe ?? false) ? Color(hex: 0xF43F5E) : Color.white)
                        .symbolEffect(.bounce, value: liveStory?.likedByMe ?? false)
                        .frame(width: 46, height: 46)
                }
                .accessibilityLabel(Text("story.like"))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .overlay(alignment: .top) {
                if sentReplyNotice {
                    Text("story.reply.sent")
                        .font(Theme.rounded(.footnote, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .offset(y: -44)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: replyText.isEmpty)
        }
    }

    // MARK: Gestures

    /// One gesture for tap left/right, hold to pause and swipe down to close.
    private func pressGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = .now
                    holdTask?.cancel()
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(220))
                        guard !Task.isCancelled else { return }
                        isHolding = true
                    }
                }
                if value.translation.height > 10, abs(value.translation.height) > abs(value.translation.width) {
                    dragOffset = value.translation.height
                    isHolding = true
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                let duration = Date.now.timeIntervalSince(pressStart ?? .now)
                pressStart = nil
                let moved = hypot(value.translation.width, value.translation.height)
                if value.translation.height > 120 {
                    close()
                    return
                }
                withAnimation(Theme.spring) { dragOffset = 0 }
                isHolding = false
                if isReplyFocused {
                    isReplyFocused = false
                    return
                }
                guard duration < 0.25, moved < 12 else { return }
                if value.startLocation.x < width * 0.3 {
                    previous()
                } else {
                    next()
                }
            }
    }

    // MARK: Logic

    private func setUp() {
        let me = appState.currentUser
        if startAuthorID == me.id {
            rings = [UserStoryRing(author: me, stories: social.myStories)]
            ringIndex = 0
            storyIndex = 0
        } else {
            rings = social.storyRings
            ringIndex = rings.firstIndex { $0.author.id == startAuthorID } ?? 0
            storyIndex = ring?.firstUnseenIndex ?? 0
        }
        if story == nil {
            dismissViewer()
        }
    }

    private func runTimer() async {
        progress = 0
        guard let story else { return }
        social.markViewed(story)
        let step = 1.0 / 60.0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            guard !isPaused, social.image(for: story.imageKey) != nil else { continue }
            progress += step / Self.storyDuration
            if progress >= 1 {
                progress = 1
                next()
                return
            }
        }
    }

    private func next() {
        guard let ring else { return dismissViewer() }
        HapticManager.shared.selection()
        if storyIndex + 1 < ring.stories.count {
            withAnimation(.easeOut(duration: 0.15)) { storyIndex += 1 }
        } else if ringIndex + 1 < rings.count {
            withAnimation(.easeInOut(duration: 0.25)) {
                ringIndex += 1
                storyIndex = rings[ringIndex].firstUnseenIndex
            }
        } else {
            dismissViewer()
        }
    }

    private func previous() {
        HapticManager.shared.selection()
        if storyIndex > 0 {
            withAnimation(.easeOut(duration: 0.15)) { storyIndex -= 1 }
        } else if ringIndex > 0 {
            withAnimation(.easeInOut(duration: 0.25)) {
                ringIndex -= 1
                storyIndex = max(0, rings[ringIndex].stories.count - 1)
            }
        } else {
            progress = 0
        }
    }

    private func like() {
        guard let liveStory else { return }
        let willLike = !liveStory.likedByMe
        social.toggleLike(liveStory)
        if willLike {
            burstHearts()
        }
    }

    private func burstHearts() {
        let new = (0..<9).map { _ in HeartParticle() }
        hearts.append(contentsOf: new)
        for particle in new {
            withAnimation(.easeOut(duration: Double.random(in: 0.9...1.4))) {
                if let index = hearts.firstIndex(where: { $0.id == particle.id }) {
                    hearts[index].x = CGFloat.random(in: -90...40)
                    hearts[index].y = CGFloat.random(in: -320 ... -140)
                    hearts[index].opacity = 0
                }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            hearts.removeAll { particle in new.contains { $0.id == particle.id } }
        }
    }

    private func sendReply() {
        guard let story else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyText = ""
        isReplyFocused = false
        Task {
            do {
                try await social.replyToStory(story, text: text)
                withAnimation(Theme.spring) { sentReplyNotice = true }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(Theme.spring) { sentReplyNotice = false }
            } catch {
                appState.showToast(.warning, title: String(localized: "toast.error.title"), subtitle: error.localizedDescription)
            }
        }
    }

    private func deleteCurrent() {
        guard let story else { return }
        Task {
            await social.deleteStory(story)
            HapticManager.shared.success()
            if var current = ring {
                current.stories.removeAll { $0.id == story.id }
                if current.stories.isEmpty {
                    dismissViewer()
                } else {
                    rings[ringIndex] = current
                    storyIndex = min(storyIndex, current.stories.count - 1)
                }
            }
        }
    }

    private func close() {
        HapticManager.shared.tap()
        dismissViewer()
    }

    private func dismissViewer() {
        holdTask?.cancel()
        social.storyViewerStart = nil
        dismiss()
    }
}

private struct HeartParticle: Identifiable {
    let id = UUID()
    var x: CGFloat = 0
    var y: CGFloat = 0
    var opacity: Double = 1
    let size = CGFloat.random(in: 16...30)
}

/// Who watched your story, with the people who left a heart first.
struct StoryViewersSheet: View {
    let story: StoryItem

    private var viewers: [StoryView] {
        story.otherViews.sorted { lhs, rhs in
            if lhs.liked != rhs.liked { return lhs.liked }
            return lhs.viewedAt > rhs.viewedAt
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewers.isEmpty {
                    ContentUnavailableView {
                        Label("story.viewers.empty.title", systemImage: "eye.slash")
                    } description: {
                        Text("story.viewers.empty.body")
                    }
                } else {
                    List(viewers, id: \.viewerID) { view in
                        HStack(spacing: 12) {
                            if let viewer = view.viewer {
                                AvatarBadge(user: viewer, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: viewer.displayName)
                                        .font(Theme.text(.subheadline, weight: .semibold))
                                    Text(verbatim: LocaleFormatter.relativeTimestamp(view.viewedAt))
                                        .font(Theme.text(.caption))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer()
                            if view.liked {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(Color(hex: 0xF43F5E))
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(Text("story.views \(viewers.count)"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
