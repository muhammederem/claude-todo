import Foundation

struct ScannedSession {
    let id: String
    let file: URL
    let mtime: Date
    let size: Int
    let cwd: String
    let fallbackTitle: String
    let turn: TurnInfo
    var name: String?
    var live = false
    var busy = false

    var todos: [TodoItem]? { turn.todos }
    var fingerprint: String { "\(Int(mtime.timeIntervalSince1970))-\(size)" }
}

/// Reads Claude Code session transcripts plus the live-session registry; no model calls.
final class TranscriptScanner: @unchecked Sendable {
    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let session: ScannedSession
    }

    private struct Registry {
        var name: String?
        var live = false
        var busy = false
    }

    private static let tailBytes = 6_000_000   // transcripts reach 40 MB+; only the end matters

    private let projectsDir: URL
    private let sessionsDir: URL
    private let maxAge: TimeInterval
    private var cache: [String: CacheEntry] = [:]

    init(claudeDir: URL, maxAge: TimeInterval = 30 * 24 * 3600) {
        self.projectsDir = claudeDir.appendingPathComponent("projects")
        self.sessionsDir = claudeDir.appendingPathComponent("sessions")
        self.maxAge = maxAge
    }

    func scan() -> [ScannedSession] {
        let fm = FileManager.default
        let registry = readRegistry()
        var result: [ScannedSession] = []
        var live = Set<String>()

        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = values.contentModificationDate,
                      Date().timeIntervalSince(mtime) < maxAge else { continue }
                let size = values.fileSize ?? 0
                live.insert(file.path)

                var session: ScannedSession
                if let hit = cache[file.path], hit.mtime == mtime, hit.size == size {
                    session = hit.session
                } else {
                    guard let parsed = parse(file: file, mtime: mtime, size: size, projectDir: dir.lastPathComponent) else { continue }
                    cache[file.path] = CacheEntry(mtime: mtime, size: size, session: parsed)
                    session = parsed
                }
                if let r = registry[session.id] {
                    session.name = r.name
                    session.live = r.live
                    session.busy = r.busy
                }
                result.append(session)
            }
        }
        cache = cache.filter { live.contains($0.key) }
        return result.sorted { $0.mtime > $1.mtime }
    }

    private func parse(file: URL, mtime: Date, size: Int, projectDir: String) -> ScannedSession? {
        guard let data = Self.readTail(file, bytes: Self.tailBytes) else { return nil }
        let todoMarker = Data("\"TodoWrite\"".utf8)
        let userMarker = Data("\"type\":\"user\"".utf8)
        let assistantMarker = Data("\"type\":\"assistant\"".utf8)
        var turn = TurnInfo()
        var cwd = ""

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let c = Self.cwd(in: line) { cwd = c }
            let hasTodo = line.range(of: todoMarker) != nil
            let isUser = line.range(of: userMarker) != nil
            let isAssistant = !isUser && line.range(of: assistantMarker) != nil
            guard hasTodo || isUser || isAssistant, hasTodo || line.count < 200_000 else { continue }   // skip huge tool results
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }

            if isUser {
                guard let text = Self.humanText(obj, message) else { continue }
                if turn.firstPrompt.isEmpty { turn.firstPrompt = text }
                turn.lastPrompt = text
                turn.lastAssistant = ""      // a new request starts a new turn
                turn.stopReason = nil
                turn.activity = ""
            } else if isAssistant {
                turn.stopReason = message["stop_reason"] as? String
                if let text = Self.text(of: message), !text.isEmpty { turn.lastAssistant = text }
                if let now = Self.activity(of: message) { turn.activity = now }
            }
            if hasTodo, let items = Self.todoList(in: message) { turn.todos = items }
        }
        guard !turn.lastPrompt.isEmpty || turn.todos != nil else { return nil }
        let fallback = cwd.isEmpty ? projectDir : (cwd as NSString).lastPathComponent
        return ScannedSession(id: file.deletingPathExtension().lastPathComponent, file: file, mtime: mtime, size: size,
                              cwd: cwd, fallbackTitle: fallback, turn: turn)
    }

    // MARK: Transcript helpers

    /// A real prompt typed by the user (not a tool result or an injected reminder).
    private static func humanText(_ obj: [String: Any], _ message: [String: Any]) -> String? {
        if let origin = obj["origin"] as? [String: Any], origin["kind"] as? String != "human" { return nil }
        guard let text = text(of: message), !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    /// A short "what is it doing" line from the last tool call in an assistant message.
    static func activity(of message: [String: Any]) -> String? {
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        func name(_ path: Any?) -> String { ((path as? String) ?? "").split(separator: "/").last.map(String.init) ?? "a file" }
        func clip(_ s: String, _ n: Int = 48) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        if let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }),
           let tn = tool["name"] as? String {
            let input = tool["input"] as? [String: Any] ?? [:]
            switch tn {
            case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing \(name(input["file_path"] ?? input["notebook_path"]))"
            case "Read": return "Reading \(name(input["file_path"]))"
            case "Grep", "Glob": return "Searching the code"
            case "Bash":
                if let d = input["description"] as? String, !d.isEmpty { return clip(d) }
                return "Running " + clip((input["command"] as? String) ?? "a command", 40)
            case "Task", "Agent": return "Sub-agent: " + clip((input["description"] as? String) ?? "working", 38)
            case "WebFetch", "WebSearch": return "Searching the web"
            case "TodoWrite":
                let todos = input["todos"] as? [[String: Any]] ?? []
                if let cur = todos.first(where: { $0["status"] as? String == "in_progress" }),
                   let f = (cur["activeForm"] ?? cur["content"]) as? String { return clip(f) }
                return "Planning the next steps"
            default: return tn.hasPrefix("mcp__") ? "Using \(tn.split(separator: "_").last.map(String.init) ?? "a tool")" : "Using \(tn)"
            }
        }
        if blocks.contains(where: { $0["type"] as? String == "text" }) { return "Writing a reply" }
        return nil
    }

    static func text(of message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func todoList(in message: [String: Any]) -> [TodoItem]? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        var latest: [TodoItem]?
        for block in content where block["type"] as? String == "tool_use" && block["name"] as? String == "TodoWrite" {
            guard let input = block["input"] as? [String: Any], let todos = input["todos"] as? [[String: Any]] else { continue }
            latest = todos.enumerated().map { index, t in
                let text = t["content"] as? String ?? ""
                return TodoItem(id: String(index), content: text, activeForm: t["activeForm"] as? String ?? text,
                                status: TodoStatus(rawValue: t["status"] as? String ?? "") ?? .pending)
            }
        }
        return latest
    }

    static func readTail(_ url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: 10) {   // drop the partial first line
            data = Data(data[data.index(after: nl)...])
        }
        return data
    }

    private static func cwd(in line: Data) -> String? {
        guard let r = line.range(of: Data("\"cwd\":\"".utf8)) else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
    }

    /// ~/.claude/sessions/<pid>.json describes every running Claude Code process; a session without one is closed.
    private func readRegistry() -> [String: Registry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var map: [String: Registry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["sessionId"] as? String else { continue }
            var entry = map[id] ?? Registry()
            if let name = obj["name"] as? String, !name.isEmpty { entry.name = name }
            if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0 || errno == EPERM {
                entry.live = true
                entry.busy = entry.busy || obj["status"] as? String == "busy"
            }
            map[id] = entry
        }
        return map
    }
}

/// Merges scan results (and the optional model summary) into the sessions shown in the UI.
func buildSessions(from scanned: [ScannedSession], analyzer: SessionAnalyzer?, dismissed: [String: String] = [:],
                   dismissedItems: Set<String> = []) -> [TodoSession] {
    let closedWindow: TimeInterval = 7 * 24 * 3600   // closed sessions with nothing pending fade out of the list
    var out: [TodoSession] = []

    for s in scanned {
        if dismissed[s.id] == s.fingerprint { continue }

        var items: [TodoItem]
        var auto = true
        var analyzing = false
        var title = s.name ?? s.fallbackTitle
        if let todos = s.todos, todos.contains(where: { $0.status != .completed }) {
            items = OpenWork.items(for: s.turn, live: s.live, busy: s.busy)
            auto = false
        } else {
            items = OpenWork.items(for: s.turn, live: s.live, busy: s.busy)
            if let analyzer {
                analyzing = analyzer.isAnalyzing(s.id)
                if let ai = analyzer.analysis(for: s.id) {
                    let t = ai.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { title = String(t.prefix(22)) }
                    // the model's list replaces the rule-based guesses; an empty list means nothing is open
                    items = ai.items.prefix(SessionAnalyzer.maxItems).enumerated().map { i, item in
                        TodoItem(id: "ai-\(i)", content: item.text, activeForm: item.text,
                                 status: item.state == "in_progress" ? .inProgress : .pending, detail: item.detail,
                                 needsYou: item.needsYou)
                    }
                    .filter { !dismissedItems.contains(itemKey(s.id, $0.content)) }
                    .partitioned()   // your items first
                } else if analyzer.isPending(s.id) {
                    items = []   // raw sentences from the chat read badly; wait for the real summary
                    analyzing = true
                }
            }
        }

        let onlyResume = items.allSatisfy { $0.kind == .resume }
        if items.isEmpty && !analyzing && !s.busy { continue }
        if !s.live, onlyResume, Date().timeIntervalSince(s.mtime) > closedWindow { continue }

        out.append(TodoSession(id: s.id, title: title, cwd: s.cwd, items: items, updatedAt: s.mtime,
                               auto: auto, analyzing: analyzing, live: s.live, busy: s.busy, lastPrompt: s.turn.lastPrompt,
                               nowDoing: s.busy ? s.turn.activity : ""))
    }

    // Running sessions first, then by recency; same-named tabs get a number so they stay distinguishable.
    out.sort { ($0.live ? 1 : 0, $0.updatedAt) > ($1.live ? 1 : 0, $1.updatedAt) }
    var seen: [String: Int] = [:]
    for i in out.indices {
        let base = out[i].title
        seen[base, default: 0] += 1
        if seen[base]! > 1 { out[i].title = "\(base) \(seen[base]!)" }
    }
    return out
}

/// Identifies one to-do inside one session, for "mark as done" (persisted by title).
func itemKey(_ sessionID: String, _ title: String) -> String {
    sessionID + "|" + title.lowercased().filter { $0.isLetter || $0.isNumber }
}

private extension Array where Element == TodoItem {
    func partitioned() -> [TodoItem] { filter(\.needsYou) + filter { !$0.needsYou } }
}
