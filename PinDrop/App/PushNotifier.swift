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

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(15))
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
        case "best_friend":
            return (String(localized: "push.bestFriend.title"), String(localized: "push.bestFriend.body \(name)"))
        default:
            return nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let present = (notification.request.content.userInfo["present"] as? String) != "0"
        return present ? [.banner, .list, .sound] : [.list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String ?? ""
        let thread = (info["thread"] as? String).flatMap(UUID.init(uuidString:))
        let ref = (info["ref"] as? String).flatMap(UUID.init(uuidString:))
        let actor = (info["actor"] as? String).flatMap(UUID.init(uuidString:))
        let route: PushRoute
        switch kind {
        case "message":
            guard let thread else { return }
            route = .chat(thread)
        case "story":
            guard let actor else { return }
            route = .story(actor)
        case "pin":
            guard let ref else { return }
            route = .pin(ref)
        default:
            route = .notifications
        }
        await MainActor.run {
            if let onOpen {
                onOpen(route)
            } else {
                pendingRoute = route
            }
        }
    }
}
