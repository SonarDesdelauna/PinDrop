import BackgroundTasks
import Foundation
import UserNotifications

/// A device notification event (`public.pending_push`).
struct PushEvent: Decodable, Sendable, Identifiable {
    let id: Int64
    let kind: String
    let sub: String?
    let detail: String?
    let refID: UUID?
    let threadID: UUID?
    let actorID: UUID?
    let actorName: String?
    let threadTitle: String?
    let threadEmoji: String?
    let threadKind: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, sub, detail
        case refID = "ref_id"
        case threadID = "thread_id"
        case actorID = "actor_id"
        case actorName = "actor_name"
        case threadTitle = "thread_title"
        case threadEmoji = "thread_emoji"
        case threadKind = "thread_kind"
    }
}

/// Where a tapped notification leads.
enum PushRoute: Sendable, Equatable {
    case chat(UUID)
    case story(UUID)
    case pin(UUID)
    case relay(UUID)
    case notifications
}

/// System notifications for what your friends do: messages, pins, capsules, stories, requests.
///
/// The app has no push server certificate, so events are fetched from Supabase and shown as
/// local notifications: every few seconds while the app is open, and whenever iOS wakes the
/// app in the background (location changes with "Always", background app refresh).
@MainActor
final class PushNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let refreshTaskID = "com.pindrop.app.refresh"

    private let dataService: SupabaseDataService
    private var isChecking = false
    private var pollTask: Task<Void, Never>?
    private var pollInterval: Duration = .seconds(15)

    /// Called when a notification is tapped.
    var onOpen: ((PushRoute) -> Void)?
    /// Whether to show a banner for this event while the app is open (e.g. not for the chat
    /// you are reading).
    var shouldPresentInForeground: ((PushEvent) -> Bool)?
    /// A tap that arrived before the session was ready.
    private(set) var pendingRoute: PushRoute?

    init(dataService: SupabaseDataService) {
        self.dataService = dataService
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: Lifecycle

    /// Asks for permission (once) and starts polling while the app is open.
    func start() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
        startPolling()
        scheduleBackgroundRefresh()
    }

    /// Polls for new events: every 15 s while the app is open, every 20 s while it is kept
    /// running in the background.
    func startPolling(every interval: Duration = .seconds(15)) {
        if pollTask != nil, interval == pollInterval { return }
        pollTask?.cancel()
        pollInterval = interval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func stop() {
        stopPolling()
        pendingRoute = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func takePendingRoute() -> PushRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    /// Asks iOS to wake the app in a while to look for new events.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Fetching

    /// Fetches new events and shows them. Safe to call often and from background wake-ups.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard let userID = try? await dataService.currentUserID() else { return }
        let key = "pindrop.push.cursor.\(userID.uuidString)"
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: key) as? NSNumber
        guard let events = try? await dataService.fetchPendingPush(after: stored?.int64Value) else { return }
        if stored == nil {
            // First run on this device: start from now, without replaying old events.
            let latest = events.first { $0.kind == "cursor" }?.id ?? 0
            defaults.set(NSNumber(value: latest), forKey: key)
            return
        }
        let fresh = events.filter { $0.kind != "cursor" }
        guard let last = fresh.last else { return }
        defaults.set(NSNumber(value: last.id), forKey: key)
        for event in fresh {
            await post(event)
        }
    }

    private func post(_ event: PushEvent) async {
        guard let text = Self.text(for: event) else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.threadIdentifier = event.threadID?.uuidString ?? event.kind
        var info: [String: String] = ["kind": event.kind]
        if let thread = event.threadID { info["thread"] = thread.uuidString }
        if let ref = event.refID { info["ref"] = ref.uuidString }
        if let actor = event.actorID { info["actor"] = actor.uuidString }
        info["present"] = (shouldPresentInForeground?(event) ?? true) ? "1" : "0"
        content.userInfo = info
        let request = UNNotificationRequest(identifier: "push-\(event.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Texts

    private static func text(for event: PushEvent) -> (title: String, body: String)? {
        let name = event.actorName ?? String(localized: "push.someone")
        let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch event.kind {
        case "message":
            let content: String
            switch event.sub {
            case "photo": content = String(localized: "push.message.photo")
            case "voice": content = String(localized: "push.message.voice")
            case "theme": content = String(localized: "push.message.theme")
            case "location": content = String(localized: "push.message.location")
            case "pin_reply": content = detail.isEmpty ? String(localized: "push.message.pinReply") : String(localized: "push.message.pinReply.text \(detail)")
            case "story_reply": content = detail.isEmpty ? String(localized: "push.message.storyReply") : String(localized: "push.message.storyReply.text \(detail)")
            default: content = detail
            }
            if event.threadKind == "direct" || event.threadTitle == nil {
                return (name, content)
            }
            let group = [event.threadEmoji, event.threadTitle].compactMap { $0 }.joined(separator: " ")
            return (group, "\(name): \(content)")
        case "pin":
            let body = event.sub == "video" ? String(localized: "push.pin.video") : String(localized: "push.pin.photo")
            return (String(localized: "push.pin.title \(name)"), detail.isEmpty ? body : "\(body) · 📍 \(detail)")
        case "capsule":
            if event.sub == "for_you" {
                return (String(localized: "push.capsule.forYou.title \(name)"), String(localized: "push.capsule.forYou.body"))
            }
            return (String(localized: "push.capsule.title \(name)"), String(localized: "push.capsule.body"))
        case "story":
            let body = event.sub == "video" ? String(localized: "push.story.video") : String(localized: "push.story.photo")
            return (String(localized: "push.story.title \(name)"), detail.isEmpty ? body : "\(body) · 📍 \(detail)")
        case "friend_request":
            return (String(localized: "push.friendRequest.title"), String(localized: "push.friendRequest.body \(name)"))
        case "friend_accepted":
            return (String(localized: "push.friendAccepted.title"), String(localized: "push.friendAccepted.body \(name)"))
        case "ping":
            return (name, String(localized: "push.ping.body"))
        case "place_reached":
            return (String(localized: "push.placeReached.title \(detail)"), String(localized: "push.placeReached.body \(name)"))
        case "relay_baton":
            return (String(localized: "push.relayBaton.title \(name)"), String(localized: "push.relayBaton.body \(detail)"))
        case "relay_leg":
            let place = event.sub?.isEmpty == false ? " · 📍 \(event.sub ?? "")" : ""
            return (String(localized: "push.relayLeg.title \(name)"), detail + place)
        case "relay_reminder":
            return (String(localized: "push.relayReminder.title"), String(localized: "push.relayReminder.body \(detail)"))
        case "relay_broken":
            return (String(localized: "push.relayBroken.title"), String(localized: "push.relayBroken.body \(name) \(detail)"))
        case "relay_finished":
            return (String(localized: "push.relayFinished.title"), String(localized: "push.relayFinished.body \(name) \(detail) \(Int(event.sub ?? "") ?? 0)"))
        case "best_friend":
            return (String(localized: "push.bestFriend.title"), String(localized: "push.bestFriend.body \(name)"))
        default:
            return nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // The completion-handler versions: iOS calls them on the main thread and expects the handler
    // there. The async versions crashed the app on launch from a tapped notification (the
    // compiler-generated bridge called the handler off the main thread).

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let present = (notification.request.content.userInfo["present"] as? String) != "0"
        completionHandler(present ? [.banner, .list, .sound] : [.list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let route = Self.route(
            kind: info["kind"] as? String ?? "",
            thread: info["thread"] as? String,
            ref: info["ref"] as? String,
            actor: info["actor"] as? String
        )
        if let route {
            Task { @MainActor [weak self] in
                // Let the first frame of the app appear before opening sheets.
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                if let onOpen = self.onOpen {
                    onOpen(route)
                } else {
                    self.pendingRoute = route
                }
            }
        }
        completionHandler()
    }

    nonisolated private static func route(kind: String, thread: String?, ref: String?, actor: String?) -> PushRoute? {
        let thread = thread.flatMap(UUID.init(uuidString:))
        let ref = ref.flatMap(UUID.init(uuidString:))
        let actor = actor.flatMap(UUID.init(uuidString:))
        switch kind {
        case "message":
            return thread.map { .chat($0) }
        case "story":
            return actor.map { .story($0) }
        case "pin":
            return ref.map { .pin($0) }
        case _ where kind.hasPrefix("relay_"):
            return ref.map { .relay($0) }
        default:
            return .notifications
        }
    }
}
