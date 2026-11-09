import CloudKit
import UserNotifications
import SwiftUI
import WidgetKit

/// The board as the Mac last published it, plus the replies sent from this phone.
@MainActor
final class PhoneStore: ObservableObject {
    static let shared = PhoneStore()

    @Published private(set) var state: WidgetState = SharedState.read() ?? .empty
    @Published private(set) var macSeen: Date? = UserDefaults.standard.object(forKey: "macSeen") as? Date
    @Published private(set) var replies: [PhoneReply] = []
    @Published private(set) var loading = false
    @Published private(set) var iCloudOK = true
    @Published private(set) var notificationsOK = true
    @Published var selectedID: String?
    @Published var editing: ReplyTarget?
    @Published var message: String?
    /// Cards approved here, so they show as sent until the next summary replaces them.
    @Published private(set) var sent = SharedState.readSent()

    struct ReplyTarget: Identifiable {
        let session: TodoSession
        let item: TodoItem?
        var id: String { session.id + "|" + (item?.id ?? "") }
    }

    /// Session tabs; "Mine" is a Mac-only list.
    var sessions: [TodoSession] { state.sessions.filter { $0.id != "manual" } }
    var selected: TodoSession? { sessions.first { $0.id == selectedID } ?? sessions.first }

    /// The Mac rewrites the board at least every 5 minutes while it is awake.
    var macAsleep: Bool { macSeen.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true }

    /// `-demo` launch argument: fictional sessions for screenshots, no iCloud.
    static let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    init() {
        if Self.demo {
            state = .sample
            macSeen = Date().addingTimeInterval(-40)
            replies = [PhoneReply(id: "r1", sessionID: "demo-1", itemTitle: "", text: "Run the full test suite before pushing",
                                  created: Date().addingTimeInterval(-600), status: .delivered, note: "Typed into the session's iTerm tab")]
            replies.append(PhoneReply(id: "r2", sessionID: "demo-2", itemTitle: "", text: "Looks good, run the migration",
                                      created: Date().addingTimeInterval(-120), status: .waiting, note: "Claude is working; sends when it stops"))
            if ProcessInfo.processInfo.arguments.contains("-demoEdit"), var s = state.sessions.first {
                s.lastReply = "I drafted three headline options for the pricing page:\n\n1. 'Pay once, keep it forever'\n2. 'Simple pricing for teams'\n3. 'Everything included, no subscriptions'\n\nWhich one should go live?"
                editing = ReplyTarget(session: s, item: s.items.first)
            }
        }
    }

    func refresh() async {
        if Self.demo { return }
        loading = true
        defer { loading = false }
        notificationsOK = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        do {
            iCloudOK = await Cloud.available()
            guard iCloudOK else {
                message = "Sign in to iCloud in Settings to see your Mac's sessions."
                return
            }
            if let snap = try await Cloud.fetchSnapshot() {
                state = snap.state
                macSeen = snap.macSeen
                UserDefaults.standard.set(snap.macSeen, forKey: "macSeen")
                SharedState.write(snap.state)
                WidgetCenter.shared.reloadAllTimelines()
            }
            replies = Array(try await Cloud.recentReplies().prefix(20))
            sent = SharedState.readSent()
            message = nil
        } catch {
            message = "Could not reach iCloud: \(error.localizedDescription)"
        }
    }

    func send(_ text: String, session: TodoSession, item: TodoItem?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await Cloud.sendReply(sessionID: session.id, itemTitle: item?.content ?? "", text: text)
            if let item { SharedState.markSent(session.id + "|" + item.id) }
            sent = SharedState.readSent()
            message = macAsleep ? "Sent. Your Mac seems asleep; it goes through when it wakes." : "Sent to your Mac."
            WidgetCenter.shared.reloadAllTimelines()
            replies = Array((try? await Cloud.recentReplies().prefix(20)) ?? [])
        } catch {
            message = "Could not send: \(error.localizedDescription)"
        }
    }

    /// From a notification action: approve as is (`edit` false) or open the editor.
    func handle(sessionID: String, itemTitle: String, suggestion: String, edit: Bool) async {
        if state.sessions.first(where: { $0.id == sessionID }) == nil { await refresh() }
        guard let session = state.sessions.first(where: { $0.id == sessionID }) else { return }
        let item = session.items.first { $0.content == itemTitle }
        selectedID = session.id
        if edit || suggestion.isEmpty {
            editing = ReplyTarget(session: session, item: item)
        } else {
            await send(suggestion, session: session, item: item)
        }
    }

    /// Widget links: `claudetodo://session?id=…` and `claudetodo://reply?id=…&item=…&edit=1`.
    func open(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard let id = value("id"), let session = state.sessions.first(where: { $0.id == id }) else { return }
        selectedID = id
        if url.host == "reply" {
            editing = ReplyTarget(session: session, item: session.items.first { $0.id == value("item") })
        }
    }

    /// Silent pushes when the board changes, and a visible one for every "waiting on you" alert from the Mac.
    func subscribe() async {
        guard !UserDefaults.standard.bool(forKey: "subscribed-v1"), await Cloud.available() else { return }
        do {
            try await Cloud.ensureZone()
            let zone = CKRecordZoneSubscription(zoneID: Cloud.zoneID, subscriptionID: "board-changes")
            let silent = CKSubscription.NotificationInfo()
            silent.shouldSendContentAvailable = true
            zone.notificationInfo = silent

            let alerts = CKQuerySubscription(recordType: Cloud.alertType, predicate: NSPredicate(value: true),
                                             subscriptionID: "alerts", options: [.firesOnRecordCreation])
            alerts.zoneID = Cloud.zoneID
            let info = CKSubscription.NotificationInfo()
            info.titleLocalizationKey = "%1$@"
            info.titleLocalizationArgs = ["title"]
            info.alertLocalizationKey = "%1$@"
            info.alertLocalizationArgs = ["body"]
            info.soundName = "default"
            info.category = PhoneDelegate.replyCategory
            info.desiredKeys = ["sessionID", "itemTitle", "suggestion"]
            alerts.notificationInfo = info

            _ = try await Cloud.db.modifySubscriptions(saving: [zone, alerts], deleting: [])
            UserDefaults.standard.set(true, forKey: "subscribed-v1")
        } catch {
            message = "Notifications are not set up yet: \(error.localizedDescription)"
        }
    }
}
