import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class TodoStore: ObservableObject {
    static let manualID = "manual"

    @Published private(set) var transcript: [TodoSession] = []
    @Published private(set) var manual: [ManualTask] = []
    @Published var selectedID: String?

    /// Optional model-written summaries (an API call per idle session); off unless the user opts in.
    @Published var smartSummary = UserDefaults.standard.object(forKey: SessionAnalyzer.defaultsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(smartSummary, forKey: SessionAnalyzer.defaultsKey)
            refresh()
        }
    }

    @Published private(set) var hiddenCount = 0
    private var dismissed = UserDefaults.standard.dictionary(forKey: "dismissedTabs") as? [String: String] ?? [:]
    private var dismissedItems = Set(UserDefaults.standard.stringArray(forKey: "dismissedItems") ?? [])
    private var fingerprints: [String: String] = [:]

    private let scanner: TranscriptScanner
    private let analyzer = SessionAnalyzer()
    private let queue = DispatchQueue(label: "claude-todo.scan", qos: .utility)
    private var timer: Timer?
    private var published: WidgetState?

    /// "Benim" tab first (always present), then one tab per Claude Code session.
    var sessions: [TodoSession] {
        let mine = manual.map { TodoItem(id: $0.id.uuidString, content: $0.text, activeForm: $0.text, status: $0.status) }
        return [TodoSession(id: Self.manualID, title: "Mine", cwd: "", items: mine, updatedAt: .distantFuture)] + transcript
    }

    var openCount: Int { sessions.reduce(0) { $0 + $1.openCount } }

    var selected: TodoSession? {
        let all = sessions
        return all.first { $0.id == selectedID } ?? all.first { $0.openCount > 0 && $0.id != Self.manualID } ?? all.first
    }

    /// Running tasks first (prefixed with `>`), then pending ones; used by the panel, menu bar and widget.
    init(autoRefresh: Bool = true) {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        scanner = TranscriptScanner(claudeDir: dir)
        analyzer.onUpdate = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        if let data = try? Data(contentsOf: SharedState.manualURL),
           let saved = try? JSONDecoder().decode([ManualTask].self, from: data) {
            manual = saved
        }
        guard autoRefresh else { return }
        publishForWidget()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                Notifier.check(self.transcript)
            }
        }
        if autoRefresh {
            Notifier.requestPermission()
            Notifier.enableLoginOnFirstRun()
        }
    }

    func refresh() {
        hiddenCount = dismissed.count + dismissedItems.count
        let smart = smartSummary
        let dismissed = dismissed
        let dismissedItems = dismissedItems
        queue.async { [scanner, analyzer] in
            let scanned = scanner.scan()
            if smart { analyzer.consider(scanned) }
            let found = buildSessions(from: scanned, analyzer: smart ? analyzer : nil, dismissed: dismissed,
                                      dismissedItems: dismissedItems)
            let prints = Dictionary(scanned.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { $1 })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fingerprints = prints
                guard found != self.transcript else { return }
                self.transcript = found
                self.publishForWidget()
            }
        }
    }

    /// Screenshot mode: show fictional sessions instead of the real ones.
    func loadDemo() { transcript = WidgetState.sample.sessions; selectedID = transcript.first?.id }

    func refreshNow() {
        let scanned = scanner.scan()
        fingerprints = Dictionary(scanned.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { $1 })
        transcript = buildSessions(from: scanned, analyzer: nil, dismissed: dismissed)
    }

    /// Hides a tab until its conversation changes again.
    func dismiss(_ session: TodoSession) {
        guard let print = fingerprints[session.id] else { return }
        dismissed[session.id] = print
        hiddenCount = dismissed.count + dismissedItems.count
        UserDefaults.standard.set(dismissed, forKey: "dismissedTabs")
        transcript.removeAll { $0.id == session.id }
        selectedID = nil
        publishForWidget()
    }

    /// "Done / ignore" on one inferred to-do: it stays gone even when the session is analyzed again.
    func finish(_ item: TodoItem, in session: TodoSession) {
        dismissedItems.insert(itemKey(session.id, item.content))
        hiddenCount = dismissed.count + dismissedItems.count
        UserDefaults.standard.set(Array(dismissedItems), forKey: "dismissedItems")
        refresh()
    }

    /// Brings back every hidden tab and every task marked as done.
    func restoreHidden() {
        dismissed = [:]
        dismissedItems = []
        UserDefaults.standard.removeObject(forKey: "dismissedTabs")
        UserDefaults.standard.removeObject(forKey: "dismissedItems")
        hiddenCount = 0
        refresh()
    }

    /// Reopens the session with `claude --resume` in the user's own terminal.
    nonisolated static func resume(sessionID: String, cwd: String) {
        TerminalLauncher.resume(sessionID: sessionID, cwd: cwd)
    }

    /// Forget every inferred list and ask the model again.
    func reanalyze() {
        analyzer.reset()
        refresh()
    }

    func addManual(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manual.append(ManualTask(id: UUID(), text: trimmed, status: .pending))
        selectedID = Self.manualID
        saveManual()
    }

    /// pending -> in progress -> done -> pending
    func cycle(_ item: TodoItem) {
        guard let i = manual.firstIndex(where: { $0.id.uuidString == item.id }) else { return }
        switch manual[i].status {
        case .pending: manual[i].status = .inProgress
        case .inProgress: manual[i].status = .completed
        case .completed: manual[i].status = .pending
        }
        saveManual()
    }

    func deleteManual(_ item: TodoItem) {
        manual.removeAll { $0.id.uuidString == item.id }
        saveManual()
    }

    func clearCompletedManual() {
        manual.removeAll { $0.status == .completed }
        saveManual()
    }

    private func saveManual() {
        try? FileManager.default.createDirectory(at: SharedState.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manual) { try? data.write(to: SharedState.manualURL, options: .atomic) }
        publishForWidget()
    }

    /// Writes state.json for the widget and nudges WidgetKit, but only when something actually changed.
    private func publishForWidget() {
        let state = WidgetState(updatedAt: .now, sessions: sessions.filter { !$0.items.isEmpty || $0.analyzing })
        if let last = published, last.sessions == state.sessions { return }
        published = state
        SharedState.write(state)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// `--dump`: print parsed sessions and exit (no UI), for checking the parser.
    nonisolated static func dumpSync() {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let scanner = TranscriptScanner(claudeDir: dir)
        for s in buildSessions(from: scanner.scan(), analyzer: nil) {
            print("[\(s.title)] \(s.live ? (s.busy ? "busy" : "live") : "closed")\(s.auto ? " auto" : " todo")")
            for i in s.items { print("  \(i.kind.rawValue)/\(i.status.rawValue): \(i.content)") }
        }
        exit(0)
    }
}
