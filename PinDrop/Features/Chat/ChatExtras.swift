import AVFoundation
import SwiftUI

// MARK: - Chat themes

/// Chat themes, like Instagram: the color of your bubbles and the background of the chat.
struct ChatTheme: Identifiable, Hashable, Sendable {
    let id: String
    let emoji: String
    let bubble: [UInt32]
    let background: [UInt32]?
    let isDark: Bool

    static let all: [ChatTheme] = [
        ChatTheme(id: "default", emoji: "💜", bubble: [0x8B5CF6, 0x6D28D9], background: nil, isDark: false),
        ChatTheme(id: "sunset", emoji: "🌅", bubble: [0xF97316, 0xEC4899], background: [0xFFE4D6, 0xFCE7F3], isDark: false),
        ChatTheme(id: "ocean", emoji: "🌊", bubble: [0x06B6D4, 0x2563EB], background: [0xD9F3FB, 0xDBEAFE], isDark: false),
        ChatTheme(id: "aurora", emoji: "🌌", bubble: [0x10B981, 0x8B5CF6], background: [0xD1FAE5, 0xEDE9FE], isDark: false),
        ChatTheme(id: "candy", emoji: "🍬", bubble: [0xF472B6, 0xA78BFA], background: [0xFCE7F3, 0xF3E8FF], isDark: false),
        ChatTheme(id: "forest", emoji: "🌲", bubble: [0x22C55E, 0x166534], background: [0xDCFCE7, 0xECFCCB], isDark: false),
        ChatTheme(id: "midnight", emoji: "🌙", bubble: [0x6366F1, 0x312E81], background: [0x1E1B4B, 0x0B0A1F], isDark: true),
        ChatTheme(id: "love", emoji: "❤️", bubble: [0xEF4444, 0xF43F5E], background: [0xFFE4E6, 0xFEE2E2], isDark: false),
        ChatTheme(id: "galaxy", emoji: "🪐", bubble: [0xA855F7, 0x06B6D4], background: [0x2E1065, 0x0C0A2A], isDark: true),
        ChatTheme(id: "lemon", emoji: "🍋", bubble: [0xFACC15, 0xF97316], background: [0xFEF9C3, 0xFFEDD5], isDark: false),
    ]

    static func named(_ id: String?) -> ChatTheme {
        all.first { $0.id == id } ?? all[0]
    }

    var name: String {
        switch id {
        case "sunset": String(localized: "chat.theme.sunset")
        case "ocean": String(localized: "chat.theme.ocean")
        case "aurora": String(localized: "chat.theme.aurora")
        case "candy": String(localized: "chat.theme.candy")
        case "forest": String(localized: "chat.theme.forest")
        case "midnight": String(localized: "chat.theme.midnight")
        case "love": String(localized: "chat.theme.love")
        case "galaxy": String(localized: "chat.theme.galaxy")
        case "lemon": String(localized: "chat.theme.lemon")
        default: String(localized: "chat.theme.default")
        }
    }

    var bubbleGradient: LinearGradient {
        LinearGradient(colors: bubble.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var accent: Color { Color(hex: bubble[0]) }

    @ViewBuilder
    var backgroundView: some View {
        if let background {
            LinearGradient(colors: background.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)
        } else {
            Theme.obsidian
        }
    }

    /// Color of timestamps and small notes on this background.
    var secondaryText: Color {
        isDark ? Color.white.opacity(0.65) : Theme.textSecondary
    }
}

/// Grid of themes for one chat.
struct ChatThemePickerSheet: View {
    let threadID: UUID
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var current: String { appState.social.thread(threadID)?.theme ?? "default" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 14) {
                    ForEach(ChatTheme.all) { theme in
                        Button {
                            choose(theme)
                        } label: {
                            VStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(theme.background.map { LinearGradient(colors: $0.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom) } ?? LinearGradient(colors: [Theme.obsidian, Theme.surface], startPoint: .top, endPoint: .bottom))
                                    VStack(alignment: .trailing, spacing: 5) {
                                        Capsule().fill(Color(hex: 0x1F1F27).opacity(0.9)).frame(width: 46, height: 14)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Capsule().fill(theme.bubbleGradient).frame(width: 56, height: 14)
                                        Capsule().fill(theme.bubbleGradient).frame(width: 38, height: 14)
                                    }
                                    .padding(12)
                                    Text(verbatim: theme.emoji)
                                        .font(.system(size: 22))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                        .padding(8)
                                }
                                .frame(height: 104)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(current == theme.id ? theme.accent : Color.white.opacity(0.15), lineWidth: current == theme.id ? 3 : 1)
                                }
                                Text(verbatim: theme.name)
                                    .font(Theme.text(.caption, weight: .bold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
                    }
                }
                .padding(16)
            }
            .background(Theme.obsidian.ignoresSafeArea())
            .navigationTitle(Text("chat.theme.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("common.done") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choose(_ theme: ChatTheme) {
        guard theme.id != current else { return dismiss() }
        Task {
            do {
                try await appState.social.setTheme(theme.id, threadID: threadID)
            } catch {
                appState.showToast(.warning, title: String(localized: "chat.send.failed"), subtitle: error.localizedDescription)
            }
        }
        dismiss()
    }
}

// MARK: - Voice recording

/// Records a voice message (AAC m4a, mono) and its waveform.
@MainActor
@Observable
final class VoiceRecorder {
    static let maxDuration: TimeInterval = 180

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Double] = []

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var url: URL?
    /// Called when the maximum length is reached.
    @ObservationIgnored var onLimit: (() -> Void)?

    /// Asks for the microphone (once) and starts recording. false when not allowed.
    func start() async -> Bool {
        guard !isRecording else { return true }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            return false
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: file, settings: settings) else { return false }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { return false }
        self.recorder = recorder
        url = file
        levels = []
        elapsed = 0
        isRecording = true
        HapticManager.shared.tap()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let db = Double(recorder.averagePower(forChannel: 0))
                let level = max(0, min(1, (db + 50) / 50))
                self.levels.append(level)
                self.elapsed = recorder.currentTime
                if self.elapsed >= Self.maxDuration {
                    self.onLimit?()
                    return
                }
            }
        }
        return true
    }

    /// Stops and returns the file, its length and waveform (nil when too short).
    func finish() -> (data: Data, durationMs: Int, waveform: String)? {
        guard let recorder, let url else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        cleanUp()
        defer { try? FileManager.default.removeItem(at: url) }
        guard duration >= 0.6, let data = try? Data(contentsOf: url) else { return nil }
        return (data, Int(duration * 1000), ChatMessage.waveform(from: levels))
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        cleanUp()
        HapticManager.shared.selection()
    }

    private func cleanUp() {
        meterTask?.cancel()
        meterTask = nil
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Voice playback

/// Plays one voice message at a time.
@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    private(set) var currentID: UUID?
    private(set) var progress: Double = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func toggle(_ id: UUID, data: Data) {
        if currentID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
                startTicker()
            }
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            currentID = id
            progress = 0
            isPlaying = true
            startTicker()
        } catch {
            stop()
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        currentID = nil
        progress = 0
        isPlaying = false
    }

    func remaining(for id: UUID, total: TimeInterval) -> TimeInterval {
        guard currentID == id, let player else { return total }
        return max(0, player.duration - player.currentTime)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying { return }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}

enum VoiceFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Bars of a waveform, filled up to `progress`.
struct WaveformBars: View {
    let levels: [Double]
    let progress: Double
    let filled: Color
    let empty: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(1, levels.count)
            let spacing: CGFloat = 2
            let width = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Double(index) / Double(count) < progress ? filled : empty)
                        .frame(width: width, height: max(3, geo.size.height * (0.15 + 0.85 * level)))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// A voice message in the conversation.
struct VoiceBubble: View {
    let message: ChatMessage
    let key: String
    let durationMs: Int
    let levels: [Double]
    let isMine: Bool
    let theme: ChatTheme

    @Environment(AppState.self) private var appState
    private var player: VoicePlayer { VoicePlayer.shared }

    private var isCurrent: Bool { player.currentID == message.id }

    var body: some View {
        let data = appState.social.data(for: key)
        let total = TimeInterval(durationMs) / 1000
        HStack(spacing: 10) {
            Button {
                guard let data else { return appState.social.loadImage(key) }
                HapticManager.shared.tap()
                player.toggle(message.id, data: data)
            } label: {
                ZStack {
                    Circle().fill(isMine ? Color.white.opacity(0.25) : theme.accent.opacity(0.9))
                    if data == nil {
                        ProgressView().tint(Color.white).scaleEffect(0.7)
                    } else {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .offset(x: isCurrent && player.isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chat.voice.play"))
            WaveformBars(
                levels: levels,
                progress: isCurrent ? player.progress : 0,
                filled: Color.white,
                empty: Color.white.opacity(0.4)
            )
            .frame(width: 130, height: 26)
            Text(verbatim: VoiceFormat.clock(isCurrent ? player.remaining(for: message.id, total: total) : total))
                .font(Theme.rounded(.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background {
            if isMine {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.bubbleGradient)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(hex: 0x1F1F27).opacity(0.92))
            }
        }
        .onAppear {
            if data == nil { appState.social.loadImage(key) }
        }
    }
}

/// ✓ sent, ✓✓ seen, 🕓 sending.
struct MessageTicks: View {
    enum Status { case sending, sent, seen }
    let state: Status
    let tint: Color
    let secondary: Color

    var body: some View {
        Group {
            switch state {
            case .sending:
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secondary)
            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(secondary)
            case .seen:
                ZStack(alignment: .leading) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark").offset(x: 5)
                }
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(tint)
                .padding(.trailing, 5)
            }
        }
        .accessibilityHidden(true)
    }
}
