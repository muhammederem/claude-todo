import Foundation

/// Snapshot the app publishes for the widget (the sandboxed widget can't read ~/.claude itself).
struct WidgetState: Codable {
    var updatedAt: Date
    var ticker: String
    var sessions: [TodoSession]

    var openCount: Int { sessions.reduce(0) { $0 + $1.openCount } }

    static let empty = WidgetState(updatedAt: .now, ticker: "", sessions: [])
    /// Fictional data for the widget gallery placeholder and the README screenshots.
    static let sample = WidgetState(
        updatedAt: .now,
        ticker: "",
        sessions: [
            TodoSession(id: "demo-1", title: "Checkout", cwd: "", items: [
                TodoItem(id: "0", content: "Approve the pricing copy", activeForm: "Approve the pricing copy", status: .pending,
                         detail: "Claude drafted three variants and is waiting for your pick.", needsYou: true),
                TodoItem(id: "1", content: "Fix failing Stripe webhook test", activeForm: "Fix failing Stripe webhook test", status: .inProgress,
                         detail: "The retry test times out after the new signature check."),
                TodoItem(id: "2", content: "Update the order confirmation email", activeForm: "Update the order confirmation email", status: .pending,
                         detail: "Template still shows the old shipping estimate."),
            ], updatedAt: .now.addingTimeInterval(-5 * 60)),
            TodoSession(id: "demo-2", title: "API v2", cwd: "", items: [
                TodoItem(id: "0", content: "Rotate the staging API key", activeForm: "Rotate the staging API key", status: .pending,
                         detail: "The key was pasted into the chat; create a new one.", needsYou: true),
                TodoItem(id: "1", content: "Run the v2 schema migration", activeForm: "Run the v2 schema migration", status: .pending,
                         detail: "Dry run passed; waiting for the go-ahead."),
            ], updatedAt: .now.addingTimeInterval(-42 * 60)),
            TodoSession(id: "demo-3", title: "Docs", cwd: "", items: [
                TodoItem(id: "0", content: "Finish the install guide", activeForm: "Finish the install guide", status: .pending,
                         detail: "Linux and Windows sections are still empty."),
            ], updatedAt: .now.addingTimeInterval(-3 * 3600), live: false),
            TodoSession(id: "demo-4", title: "Onboarding flow", cwd: "", items: [
                TodoItem(id: "0", content: "Choose the empty-state illustration", activeForm: "Choose the empty-state illustration", status: .pending,
                         detail: "Two options generated; needs your decision.", needsYou: true),
            ], updatedAt: .now.addingTimeInterval(-2 * 24 * 3600), live: false),
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
