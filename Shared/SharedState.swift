import Foundation

/// Snapshot the app publishes for the widget (the sandboxed widget can't read ~/.claude itself).
struct WidgetState: Codable {
    var updatedAt: Date
    var ticker: String
    var sessions: [TodoSession]

    var openCount: Int { sessions.reduce(0) { $0 + $1.openCount } }

    static let empty = WidgetState(updatedAt: .now, ticker: "", sessions: [])
    static let sample = WidgetState(
        updatedAt: .now,
        ticker: ">UI KURULUYOR  *  TEST ET",
        sessions: [
            TodoSession(id: "a", title: "Ses modeli", cwd: "", items: [
                TodoItem(id: "0", content: "Gradio arayüzünü yaz", activeForm: "Gradio arayüzü yazılıyor", status: .inProgress),
                TodoItem(id: "1", content: "README hazırla", activeForm: "README", status: .pending),
                TodoItem(id: "2", content: "GitHub'ı public aç", activeForm: "GitHub", status: .pending),
            ], updatedAt: .now, auto: true),
            TodoSession(id: "b", title: "Harness", cwd: "", items: [
                TodoItem(id: "0", content: "ngrok alan adını bağla", activeForm: "ngrok bağlanıyor", status: .inProgress),
                TodoItem(id: "1", content: "Google OAuth kur", activeForm: "OAuth", status: .pending),
            ], updatedAt: .now, auto: true),
            TodoSession(id: "c", title: "Benim", cwd: "", items: [
                TodoItem(id: "0", content: "Diş hekimi randevusu", activeForm: "Randevu", status: .pending),
            ], updatedAt: .now),
        ])
}

enum SharedState {
    /// Real (unsandboxed) data directory. `CLAUDE_TODO_DATA` points at a manual.json elsewhere, for tests.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_TODO_DATA"] {
            return URL(fileURLWithPath: override).deletingLastPathComponent()
        }
        // NSHomeDirectory() is the container inside a sandbox, so ask the user database instead.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/ClaudeTodo")
    }

    static var manualURL: URL { directory.appendingPathComponent("manual.json") }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }
    static var selectionURL: URL { directory.appendingPathComponent("widget-selection.json") }

    /// Session tab last picked on the widget.
    static func readSelection() -> String? {
        (try? String(contentsOf: selectionURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeSelection(_ id: String) {
        try? id.write(to: selectionURL, atomically: true, encoding: .utf8)
    }

    static func read() -> WidgetState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: data)
    }

    static func write(_ state: WidgetState) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}
