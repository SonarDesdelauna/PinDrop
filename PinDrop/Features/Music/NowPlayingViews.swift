import MediaPlayer
import SwiftUI

// MARK: - Models

/// What someone is listening to (`public.now_playing`), refreshed by the server every 30 s.
struct NowPlaying: Decodable, Hashable, Sendable {
    let userID: UUID
    let provider: String
    let track: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let trackURL: URL?
    let isPlaying: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case provider, track, artist, album
        case artworkURL = "artwork_url"
        case trackURL = "track_url"
        case isPlaying = "is_playing"
        case updatedAt = "updated_at"
    }

    /// Playing right now (seen by the server in the last few minutes).
    func isLive(at date: Date = .now) -> Bool {
        isPlaying && date.timeIntervalSince(updatedAt) < 6 * 60
    }

    var providerName: String {
        switch provider {
        case "spotify": "Spotify"
        case "lastfm": "Last.fm"
        default: "Apple Music"
        }
    }

    var providerTint: Color {
        switch provider {
        case "spotify": Color(hex: 0x1DB954)
        case "lastfm": Color(hex: 0xD51007)
        default: Color(hex: 0xFA2D48)
        }
    }
}

/// Which music sources you linked (`music_status()`).
struct MusicStatus: Decodable, Hashable, Sendable {
    let spotifyClientID: String?
    let lastfmAvailable: Bool
    let spotifyConnected: Bool
    let spotifyError: String?
    let lastfmUsername: String?

    enum CodingKeys: String, CodingKey {
        case spotifyClientID = "spotify_client_id"
        case lastfmAvailable = "lastfm_available"
        case spotifyConnected = "spotify_connected"
        case spotifyError = "spotify_error"
        case lastfmUsername = "lastfm_username"
    }
}

// MARK: - Apple Music (only while the app is open: iOS gives no background access)

@MainActor
enum AppleMusicReporter {
    private static let key = "pindrop.music.appleMusic"
    private static var lastReported: String?

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            MPMediaLibrary.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Sends the song playing in the Music app, when it changed.
    static func reportIfNeeded(using service: SupabaseDataService) async {
        guard isEnabled, MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        let item = player.nowPlayingItem
        let playing = player.playbackState == .playing
        let title = item?.title ?? ""
        let artist = item?.artist ?? ""
        let album = item?.albumTitle ?? ""
        let signature = playing ? "\(title)|\(artist)" : "paused|\(title)"
        guard signature != lastReported else { return }
        lastReported = signature
        try? await service.reportNowPlaying(track: playing ? title : "", artist: artist, album: album, isPlaying: playing)
    }
}

// MARK: - Views

/// Album art with a provider-coloured fallback.
struct NowPlayingArtwork: View {
    let nowPlaying: NowPlaying
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(nowPlaying.providerTint.gradient)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Color.white)
            if let url = nowPlaying.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// Three little bars bouncing while the song plays.
struct EqualizerBars: View {
    var tint: Color = Theme.emerald
    var isAnimating = true
    @State private var phase = false
    private let high: [CGFloat] = [11, 5, 9]
    private let low: [CGFloat] = [4, 11, 6]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: isAnimating ? (phase ? high[index] : low[index]) : 4)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .onAppear {
            guard isAnimating else { return }
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}

/// A card with someone's current (or last) song.
struct NowPlayingCard: View {
    let nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let live = nowPlaying.isLive(at: context.date)
            HStack(spacing: 12) {
                NowPlayingArtwork(nowPlaying: nowPlaying, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if live {
                            EqualizerBars(tint: nowPlaying.providerTint)
                        }
                        Text(live ? "music.listening" : "music.lastListened")
                            .font(Theme.text(.caption, weight: .bold))
                            .foregroundStyle(nowPlaying.providerTint)
                        if !live {
                            Text(verbatim: "· " + LocaleFormatter.relativeTimestamp(nowPlaying.updatedAt, relativeTo: context.date))
                                .font(Theme.text(.caption2, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Text(verbatim: nowPlaying.track)
                        .font(Theme.text(.subheadline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: nowPlaying.artist)
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let url = nowPlaying.trackURL {
                    Link(destination: url) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(nowPlaying.providerTint))
                    }
                    .accessibilityLabel(Text("music.open \(nowPlaying.providerName)"))
                }
            }
            .padding(14)
            .glassCard()
        }
    }
}

/// Link Last.fm (Spotify, YouTube Music, Apple Music via scrobbling) and Apple Music.
struct MusicConnectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var lastfmName = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var appleMusicOn = AppleMusicReporter.isEnabled

    private var status: MusicStatus? { appState.musicStatus }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 66, height: 66)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.accentGradient))
                        Text("music.connect.title")
                            .font(Theme.text(.title3, weight: .heavy))
                            .foregroundStyle(Theme.textPrimary)
                        Text("music.connect.subtitle")
                            .font(Theme.text(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    if let mine = appState.nowPlaying(for: appState.currentUser.id) {
                        NowPlayingCard(nowPlaying: mine)
                    }

                    lastfmCard
                    appleMusicCard

                    if let message {
                        Text(verbatim: message)
                            .font(Theme.text(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
            .background(Theme.obsidian.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("common.done").fontWeight(.semibold)
                    }
                }
            }
            .task {
                await appState.reloadMusic()
                lastfmName = appState.musicStatus?.lastfmUsername ?? ""
            }
        }
        .preferredColorScheme(.light)
    }

    private func sourceHeader(_ name: String, tint: Color, symbol: String, connected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(tint))
            Text(verbatim: name)
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 6)
            if connected {
                Label("music.connected", systemImage: "checkmark.circle.fill")
                    .font(Theme.text(.caption, weight: .bold))
                    .foregroundStyle(Theme.emerald)
            }
        }
    }

    private var lastfmCard: some View {
        let linked = status?.lastfmUsername
        return VStack(alignment: .leading, spacing: 10) {
            sourceHeader("Last.fm", tint: Color(hex: 0xD51007), symbol: "dot.radiowaves.left.and.right", connected: linked != nil)
            Text("music.lastfm.hint")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if status?.lastfmAvailable == false {
                Text("music.notConfigured")
                    .font(Theme.text(.caption, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            } else {
                HStack(spacing: 8) {
                    TextField("music.lastfm.placeholder", text: $lastfmName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.text(.body, weight: .medium))
                        .padding(10)
                        .glassCard(cornerRadius: 14)
                    Button {
                        let name = lastfmName.trimmingCharacters(in: .whitespacesAndNewlines)
                        run { try await appState.dataService.linkLastfm(name) }
                    } label: {
                        Text("music.save")
                    }
                    .buttonStyle(SmallPillButtonStyle(isProminent: true))
                    .disabled(isWorking || lastfmName.trimmingCharacters(in: .whitespaces).count < 2)
                }
                if linked != nil {
                    Button(role: .destructive) {
                        run { try await appState.dataService.unlinkMusic("lastfm") }
                        lastfmName = ""
                    } label: {
                        Text("music.disconnect")
                    }
                    .buttonStyle(SmallPillButtonStyle(isProminent: false))
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    private var appleMusicCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { appleMusicOn },
                set: { newValue in
                    Task {
                        if newValue {
                            let granted = await AppleMusicReporter.requestAccess()
                            AppleMusicReporter.isEnabled = granted
                            appleMusicOn = granted
                            if granted {
                                await AppleMusicReporter.reportIfNeeded(using: appState.dataService)
                            }
                        } else {
                            AppleMusicReporter.isEnabled = false
                            appleMusicOn = false
                            try? await appState.dataService.unlinkMusic("apple")
                        }
                        await appState.reloadMusic()
                    }
                }
            )) {
                sourceHeader("Apple Music", tint: Color(hex: 0xFA2D48), symbol: "music.note", connected: false)
            }
            .tint(Theme.neonPurple)
        }
        .padding(16)
        .glassCard()
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        message = nil
        Task {
            do {
                try await action()
            } catch {
                message = String(localized: "music.error")
            }
            await appState.reloadMusic()
            isWorking = false
        }
    }
}

// MARK: - Headphones on the avatar while listening

/// Headphones around a round avatar that bob to the beat, with little notes floating out.
struct ListeningHeadphones: View {
    /// Diameter of the avatar the headphones sit on.
    let size: CGFloat
    var tint: Color = Theme.electricViolet

    @State private var bob = false

    private var cupSize: CGSize { CGSize(width: size * 0.26, height: size * 0.42) }

    var body: some View {
        ZStack {
            // Headband over the top of the head.
            Circle()
                .trim(from: 0.56, to: 0.94)
                .stroke(
                    LinearGradient(colors: [Color(hex: 0x27272A), Color(hex: 0x52525B)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: max(2.5, size * 0.11), lineCap: .round)
                )
                .frame(width: size * 1.22, height: size * 1.22)
            // Ear cups.
            HStack(spacing: size * 1.02) {
                cup
                cup
            }
            .offset(y: size * 0.06)
            // Notes.
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        note(index: index, time: time)
                    }
                }
            }
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .rotationEffect(.degrees(bob ? 5 : -5))
        .offset(y: bob ? -1 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }

    private var cup: some View {
        RoundedRectangle(cornerRadius: cupSize.width * 0.5, style: .continuous)
            .fill(LinearGradient(colors: [tint, Theme.neonPurple], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: cupSize.width * 0.5, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 1.5)
            )
            .frame(width: cupSize.width, height: cupSize.height)
            .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
    }

    /// A note rising from one of the cups, drifting outwards and fading.
    private func note(index: Int, time: Double) -> some View {
        let period = 2.4
        let progress = ((time + Double(index) * period / 3).truncatingRemainder(dividingBy: period)) / period
        let side: Double = index.isMultiple(of: 2) ? 1 : -1
        let x = side * (Double(size) * 0.62 + progress * Double(size) * 0.35) + sin(progress * .pi * 3) * 3
        let y = -progress * Double(size) * 0.95
        let opacity = progress < 0.15 ? progress / 0.15 : max(0, 1 - (progress - 0.15) / 0.85)
        return Image(systemName: index == 1 ? "music.note" : "music.quarternote.3")
            .font(.system(size: max(8, size * 0.3), weight: .bold))
            .foregroundStyle(tint)
            .shadow(color: Color.white, radius: 1)
            .rotationEffect(.degrees(side * progress * 25))
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}
