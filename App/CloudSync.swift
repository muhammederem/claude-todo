import CloudKit
import Foundation

/// Mac side of the iPhone companion: publishes the board to the user's private iCloud database, passes replies sent
/// from the phone to their sessions, and posts "waiting on you" alerts the phone turns into notifications.
/// Off until the user switches it on; nothing leaves the Mac otherwise.
@MainActor
final class CloudSync {
    static let shared = CloudSync()
    static let defaultsKey = "iphoneSync"
    private static let tokenKey = "cloudReplyToken"

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey); if newValue { lastBeat = .distantPast } }
    }
    /// Shown in the panel when sync is on but iCloud is not usable.
    private(set) var problem: String?

    private var zoneReady = false
    private var latest: WidgetState?
    private var publishedData: Data?
    private var lastBeat = Date.distantPast
    private var lastPoll = Date.distantPast
    private var working = false
    /// Replies not settled yet (pending, or waiting for a busy session), by record name.
    private var open: [String: PhoneReply] = [:]
    private var token: CKServerChangeToken? {
        get {
            UserDefaults.standard.data(forKey: Self.tokenKey)
                .flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        }
        set {
            let data = newValue.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            UserDefaults.standard.set(data, forKey: Self.tokenKey)
        }
    }

    func publish(_ state: WidgetState) { latest = state }

    /// Called every couple of seconds by the store; does real work at most every 10 s.
    func tick(sessions: [TodoSession]) {
        guard enabled, !working, Date().timeIntervalSince(lastPoll) >= 10 else { return }
        lastPoll = .now
        working = true
        let state = latest
        Task {
            defer { working = false }
            do {
                try await prepare()
                try await pushSnapshot(state)
                try await handleReplies(sessions)
                problem = nil
            } catch {
                problem = (error as? CKError)?.code == .notAuthenticated
                    ? "iPhone sync needs iCloud: sign in under System Settings › Apple Account."
                    : "iPhone sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func prepare() async throws {
        guard !zoneReady else { return }
        guard await Cloud.available() else { throw CKError(.notAuthenticated) }
        try await Cloud.ensureZone()
        try? await Cloud.cleanup()
        zoneReady = true
    }

    /// Writes the board when it changed, and every 5 minutes anyway so the phone knows the Mac is awake.
    private func pushSnapshot(_ state: WidgetState?) async throws {
        guard let state else { return }
        let data = try JSONEncoder().encode(state.sessions)
        guard data != publishedData || Date().timeIntervalSince(lastBeat) > 300 else { return }
        try await Cloud.saveSnapshot(state)
        publishedData = data
        lastBeat = .now
    }

    private func handleReplies(_ sessions: [TodoSession]) async throws {
        let (changed, next) = try await Cloud.changedReplies(since: token)
        token = next
        for r in changed where r.status == .pending || r.status == .waiting { open[r.id] = r }
        for r in changed where r.status == .delivered || r.status == .failed { open[r.id] = nil }

        for var reply in open.values.sorted(by: { $0.created < $1.created }) {
            guard let session = sessions.first(where: { $0.id == reply.sessionID }) else {
                reply.status = .failed
                reply.note = "This session is no longer on the Mac's list"
                open[reply.id] = nil
                try? await Cloud.update(reply)
                continue
            }
            if session.busy {
                // typing while Claude works would land in the middle of its turn; wait until it stops
                if reply.status != .waiting {
                    reply.status = .waiting
                    reply.note = "Claude is working; sends when it stops"
                    open[reply.id] = reply
                    try? await Cloud.update(reply)
                }
                continue
            }
            let (id, cwd, text) = (session.id, session.cwd, reply.text)
            let result = await Task.detached { TerminalLauncher.deliverRemote(sessionID: id, cwd: cwd, text: text) }.value
            reply.status = result.ok ? .delivered : .failed
            reply.note = result.note
            open[reply.id] = nil
            try? await Cloud.update(reply)
        }
    }

    /// Mirrors a Mac "waiting on you" notification to the phone.
    func alert(session: TodoSession, item: TodoItem) {
        guard enabled else { return }
        let body = item.detail.isEmpty ? item.content : "\(item.content): \(item.detail)"
        Task {
            try? await Cloud.postAlert(title: "Waiting on you · \(session.title)", body: body, sessionID: session.id,
                                       itemTitle: item.content, suggestion: item.suggestion)
        }
    }
}
