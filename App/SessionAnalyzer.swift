import Foundation

struct AIItem: Codable, Hashable {
    var text: String
    var detail = ""
    var state: String
    var needsYou = false
}

struct Analysis: Codable {
    var fingerprint: String
    var title: String
    var items: [AIItem]
    var at: Date
}

/// Asks a small model (via the user's own `claude -p`) what each idle session left unfinished.
final class SessionAnalyzer: @unchecked Sendable {
    static let defaultsKey = "smartSummary"
    private static let idleSeconds: TimeInterval = 45
    static let maxItems = 3
    /// Bump when the prompt changes so cached answers are regenerated.
    private static let promptVersion = "-v4"
    private static let retryAfter: TimeInterval = 10 * 60

    private static let systemPrompt = """
    You read the end of a Claude Code session and write the to-do list of what is still unfinished, for a small widget. \
    Include only real, concrete work that is still open: things the user asked for that are not done, steps Claude proposed \
    or asked permission for and that nobody confirmed yet, and work cut short by an error or interruption. Never include \
    finished work, politeness ("let me know"), or invented filler; if nothing is open, return an empty list. \
    Write like a good task list: "title" is a short imperative task name (2-6 words, e.g. "Deploy the login fix"); \
    "detail" is one plain sentence (under 90 characters) saying what exactly is left and why it is waiting \
    (e.g. "Needs your OK before the change goes to production"). At most 3 items, most important first. \
    "title" in the outer object names the session by its topic: 1-3 words, at most 18 characters, \
    title case, no punctuation (e.g. "Voice cloning", "Widget polish", "Clear Good release"). \
    Write in English, even if the conversation is in another language. \
    Set "owner" to "you" when the item waits on the user (an approval, a decision, a key or account they must provide, \
    something only they can do) and to "claude" when Claude can just do it. \
    Reply with only this JSON: {"title":"session name","items":[{"title":"...","detail":"...","state":"in_progress|pending","owner":"you|claude"}]}. \
    Use "in_progress" only for what the session is doing right now; everything else is "pending".
    """

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "claude-todo.analyze"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 3   // a handful of sessions at once, not one after another
        return q
    }()
    private let lock = NSLock()
    private var cache: [String: Analysis] = [:]
    private var running = Set<String>()
    private var failedUntil: [String: Date] = [:]
    private let storeURL = SharedState.directory.appendingPathComponent("analysis.json")

    /// Called (on an arbitrary queue) whenever a new analysis lands.
    var onUpdate: (() -> Void)?

    /// On by default (needs the claude CLI): it sends conversation text to the model through the user's own `claude -p`.
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }

    init() {
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([String: Analysis].self, from: data) {
            cache = saved
        }
    }

    func analysis(for id: String) -> Analysis? { lock.withLock { cache[id] } }
    func isAnalyzing(_ id: String) -> Bool { lock.withLock { running.contains(id) } }
    /// Enabled, no answer yet and no failure on record: an answer is on its way.
    func isPending(_ id: String) -> Bool {
        lock.withLock { enabled && claudePath() != nil && cache[id] == nil && (failedUntil[id] ?? .distantPast) <= Date() }
    }

    /// Why summaries are not appearing, for a notice in the panel; nil when all is well.
    var problem: String? {
        guard enabled else { return nil }
        if claudePath() == nil { return "Claude Code not found: AI summaries are off." }
        let failing = lock.withLock { failedUntil.values.contains { $0 > Date() } }
        return failing ? "Summaries failed. Is Claude Code logged in? Run `claude` once in a terminal." : nil
    }

    func reset() {
        lock.withLock { cache = [:]; failedUntil = [:] }
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Queues every idle session whose transcript changed since its last analysis.
    func consider(_ sessions: [ScannedSession]) {
        guard enabled else { return }
        // running sessions first; long-closed ones are not worth a model call
        let week: TimeInterval = 7 * 24 * 3600
        for s in sessions.sorted(by: { ($0.live ? 1 : 0, $0.mtime) > ($1.live ? 1 : 0, $1.mtime) }) where s.todos == nil {
            if !s.live, Date().timeIntervalSince(s.mtime) > week { continue }
            guard Date().timeIntervalSince(s.mtime) >= Self.idleSeconds else { continue }
            let go: Bool = lock.withLock {
                if running.contains(s.id) { return false }
                if cache[s.id]?.fingerprint == s.fingerprint + Self.promptVersion { return false }
                if let until = failedUntil[s.id], until > Date() { return false }
                running.insert(s.id)
                return true
            }
            if go { queue.addOperation { [self] in analyze(s) } }
        }
    }

    private func analyze(_ s: ScannedSession) {
        defer { lock.withLock { _ = running.remove(s.id) }; onUpdate?() }
        guard let digest = Self.digest(for: s),
              let output = runClaude(input: digest),
              let parsed = Self.parse(output) else {
            lock.withLock { failedUntil[s.id] = Date().addingTimeInterval(Self.retryAfter) }
            return
        }
        let result = Analysis(fingerprint: s.fingerprint + Self.promptVersion, title: parsed.title, items: parsed.items, at: Date())
        lock.withLock { cache[s.id] = result }
        save()
    }

    private func save() {
        let snapshot = lock.withLock { cache }
        try? FileManager.default.createDirectory(at: SharedState.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: storeURL, options: .atomic) }
    }

    // MARK: claude -p

    private func claudePath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func runClaude(input: String) -> Data? {
        guard let exe = claudePath() else { return nil }
        let process = Process()
        process.executableURL = exe
        // --no-session-persistence keeps these runs out of ~/.claude/projects (otherwise we would analyze ourselves).
        process.arguments = ["-p", "--model", "haiku", "--no-session-persistence", "--output-format", "json",
                             "--tools", "", "--disable-slash-commands", "--system-prompt", Self.systemPrompt]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // A hung run must not block the queue forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { if process.isRunning { process.terminate() } }

        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// `claude -p --output-format json` wraps the model text in `result`; the text itself holds our JSON.
    static func parse(_ output: Data) -> (title: String, items: [AIItem])? {
        guard let outer = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              outer["is_error"] as? Bool != true,
              let text = outer["result"] as? String,
              let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let inner = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any]
        else { return nil }
        let items = (inner["items"] as? [[String: Any]] ?? []).compactMap { raw -> AIItem? in
            guard let t = ((raw["title"] ?? raw["text"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let d = (raw["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AIItem(text: t, detail: d, state: raw["state"] as? String == "in_progress" ? "in_progress" : "pending",
                          needsYou: raw["owner"] as? String == "you")
        }
        return (inner["title"] as? String ?? "", Array(items.prefix(Self.maxItems)))
    }

    // MARK: digest

    /// Compact text of the end of the conversation: what was asked, what Claude said, how it stopped.
    static func digest(for s: ScannedSession) -> String? {
        guard let data = TranscriptScanner.readTail(s.file, bytes: 3_000_000) else { return nil }
        var lines: [String] = []
        var lastStop: String?
        var lastAssistantText = ""

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) where line.count < 200_000 {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }

            if type == "user" {
                // tool results come back as "user" entries too; only real prompts count
                guard (obj["origin"] as? [String: Any])?["kind"] as? String == "human",
                      let text = plainText(message), !text.isEmpty else { continue }
                lines.append("[kullanici] " + String(text.prefix(500)))
            } else {
                lastStop = message["stop_reason"] as? String
                if let text = plainText(message), !text.isEmpty {
                    lastAssistantText = text
                    lines.append("[claude] " + String(text.suffix(700)))   // questions and offers sit at the end
                }
                // long tool runs would crowd out the conversation, so keep a single marker per run
                if !toolNames(message).isEmpty, lines.last?.hasPrefix("[claude arac]") != true { lines.append("[claude arac] calisiyor") }
            }
        }
        guard !lines.isEmpty else { return nil }

        var out = "[proje] \(s.cwd)\n[son hareket] \(Int(Date().timeIntervalSince(s.mtime) / 60)) dk once\n"
        var body = ""
        for line in lines.reversed() {
            if body.count + line.count > 12_000 { break }
            body = line + "\n" + body
        }
        out += body
        if lastStop == "tool_use" { out += "[son durum] oturum bir arac cagrisinin ortasinda bitti; is yarim kalmis olabilir\n" }
        if lastAssistantText.hasPrefix("API Error") { out += "[son durum] oturum API hatasiyla kesildi; son istek tamamlanmadi\n" }
        return out
    }

    private static func plainText(_ message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolNames(_ message: [String: Any]) -> [String] {
        (message["content"] as? [[String: Any]] ?? []).compactMap {
            $0["type"] as? String == "tool_use" ? $0["name"] as? String : nil
        }
    }
}
