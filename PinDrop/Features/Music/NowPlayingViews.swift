import AuthenticationServices
import CryptoKit
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

// MARK: - Spotify sign-in (PKCE, no secret on the device)

enum SpotifyLink {
    static let redirectURI = "pindrop://spotify-callback"
    static let scopes = "user-read-currently-playing user-read-playback-state"

    struct Tokens: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    enum LinkError: Error {
        case missingCode
        case exchangeFailed
    }

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(clientID: String, verifier: String) -> URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "scope", value: scopes),
        ]
        return components?.url
    }

    static func exchange(code: String, verifier: String, clientID: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LinkError.exchangeFailed }
        return try JSONDecoder().decode(Tokens.self, from: data)
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

/// Link Spotify / Last.fm / Apple Music.
struct MusicConnectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
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

                    spotifyCard
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

    private var spotifyCard: some View {
        let connected = status?.spotifyConnected == true
        return VStack(alignment: .leading, spacing: 10) {
            sourceHeader("Spotify", tint: Color(hex: 0x1DB954), symbol: "waveform", connected: connected)
            Text("music.spotify.hint")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if connected {
                Button(role: .destructive) {
                    run { try await appState.dataService.unlinkMusic("spotify") }
                } label: {
                    Text("music.disconnect")
                }
                .buttonStyle(SmallPillButtonStyle(isProminent: false))
            } else if status?.spotifyClientID == nil {
                Text("music.notConfigured")
                    .font(Theme.text(.caption, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            } else {
                Button {
                    connectSpotify()
                } label: {
                    Label("music.spotify.connect", systemImage: "link")
                }
                .buttonStyle(SmallPillButtonStyle(isProminent: true))
                .disabled(isWorking)
            }
        }
        .padding(16)
        .glassCard()
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
            Text("music.apple.hint")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func connectSpotify() {
        guard let clientID = status?.spotifyClientID else { return }
        let verifier = SpotifyLink.makeVerifier()
        guard let url = SpotifyLink.authorizeURL(clientID: clientID, verifier: verifier) else { return }
        run {
            let callback = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "pindrop", preferredBrowserSession: .shared)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else { throw SpotifyLink.LinkError.missingCode }
            let tokens = try await SpotifyLink.exchange(code: code, verifier: verifier, clientID: clientID)
            guard let refresh = tokens.refresh_token else { throw SpotifyLink.LinkError.exchangeFailed }
            try await appState.dataService.linkSpotify(refreshToken: refresh, accessToken: tokens.access_token, expiresIn: tokens.expires_in)
            HapticManager.shared.success()
        }
    }
}
