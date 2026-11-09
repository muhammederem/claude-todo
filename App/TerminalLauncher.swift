import AppKit

/// Reopens a Claude Code session in the terminal the user actually uses.
/// macOS has no "default terminal" setting, so we look at where the session ran, then at what is open now.
enum TerminalLauncher {
    private static let known = ["Terminal", "iTerm", "Ghostty", "WezTerm", "Warp", "kitty", "Alacritty", "Hyper", "Tabby", "Rio"]
    private static let defaultsKey = "lastTerminalApp"

    enum ReplyOutcome { case sent, copied, failed }

    /// Answers a session with `text`. A closed session reopens with the text as its first prompt; a running one
    /// cannot be typed into safely, so the text goes to the clipboard and its terminal comes to the front.
    @discardableResult
    static func reply(sessionID: String, cwd: String, text: String) -> ReplyOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(sessionID), !text.isEmpty else { return .failed }
        if isRunning(sessionID) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return focusRunning(sessionID) ? .copied : .failed
        }
        resume(sessionID: sessionID, cwd: cwd, prompt: text)
        return .sent
    }

    static func isRunning(_ sessionID: String) -> Bool {
        guard let pid = pid(of: sessionID) else { return false }
        return kill(pid, 0) == 0
    }

    private static func isValid(_ id: String) -> Bool {
        id.range(of: #"^[0-9a-fA-F-]{8,64}$"#, options: .regularExpression) != nil
    }

    /// A reply that came from the iPhone while the user is away from the Mac: a running session in Terminal or iTerm
    /// gets it typed into its own tab; otherwise the session continues in Claude Desktop when installed, else in a
    /// new terminal window. Returns what was done, for the phone.
    static func deliverRemote(sessionID: String, cwd: String, text: String) -> (ok: Bool, note: String) {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard isValid(sessionID), !flat.isEmpty else { return (false, "Empty reply") }
        if let pid = pid(of: sessionID), kill(pid, 0) == 0, let host = hostApp(of: pid),
           let tty = ps(pid, field: "tty").map({ "/dev/" + $0 }), host == "Terminal" || host == "iTerm" {
            if type(flat, into: tty, host: host) { return (true, "Typed into the session's \(host) tab") }
        }
        if let desktop = desktopApp(), let claude = claudePath() {
            let p = Process()
            p.executableURL = claude
            p.arguments = ["--desktop", "--resume", sessionID, flat]
            p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
            if (try? p.run()) != nil { return (true, "Continued in \(desktop)") }
        }
        let app = terminal(for: sessionID)
        resume(sessionID: sessionID, cwd: cwd, prompt: flat, focusExisting: false)
        return (true, "Continued in a new \(app) window")
    }

    /// Types a line into the Terminal/iTerm tab that owns `tty` and presses Return. Nothing is sent anywhere else.
    private static func type(_ text: String, into tty: String, host: String) -> Bool {
        let t = escapeAS(text)
        let script = host == "iTerm" ? """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell s to write text "\(t)" newline no
                            delay 0.3
                            tell s to write text (ASCII character 13) newline no
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """ : """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        do script "\(t)" in t
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
        return runCapture(script) == "ok"
    }

    /// Claude Desktop's name when it is installed.
    private static func desktopApp() -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil ? "Claude Desktop" : nil
    }

    static func claudePath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func resume(sessionID: String, cwd: String, prompt: String? = nil, focusExisting: Bool = true) {
        guard isValid(sessionID) else { return }
        // already open in some terminal: bring that one forward instead of starting a second copy
        if focusExisting, focusRunning(sessionID) { return }
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        var command = "cd \(shellQuote(dir)) && claude --resume \(sessionID)"
        if let prompt, !prompt.isEmpty {
            // one line: terminals that type the command would submit at the first newline
            let flat = prompt.components(separatedBy: .newlines).joined(separator: " ")
            command += " " + shellQuote(flat)
        }
        let app = terminal(for: sessionID)
        UserDefaults.standard.set(app, forKey: defaultsKey)
        switch app {
        case "iTerm":
            run("""
            tell application "iTerm"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(escapeAS(command))"
            end tell
            """)
        case "Terminal":
            run("tell application \"Terminal\"\nactivate\ndo script \"\(escapeAS(command))\"\nend tell")
        default:
            // other terminals open an executable .command script
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-todo-\(sessionID).command")
            let script = "#!/bin/zsh\n\(command)\n"
            guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app, file.path]
            try? p.run()
        }
    }

    /// Brings the window that hosts a still-running session to the front. Terminal and iTerm can select the exact
    /// tab by its tty; other apps (Warp, Ghostty, …) have no scripting for that, so only the app is activated.
    private static func focusRunning(_ sessionID: String) -> Bool {
        guard let pid = pid(of: sessionID), kill(pid, 0) == 0, let host = hostApp(of: pid) else { return false }
        let tty = ps(pid, field: "tty").map { "/dev/" + $0 } ?? ""
        switch host {
        case "Terminal" where !tty.isEmpty:
            run("""
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)
        case "iTerm" where !tty.isEmpty:
            run("""
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        default:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", host]
            try? p.run()
        }
        return true
    }

    /// First app bundle above the process in the tree, e.g. "Warp".
    private static func hostApp(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<12 {
            guard let line = ps(current, field: "ppid=,comm=") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let parent = Int32(parts[0]), parent > 1 else { return nil }
            if let r = parts[1].range(of: ".app/"), let slash = parts[1][..<r.lowerBound].lastIndex(of: "/") {
                return String(parts[1][parts[1].index(after: slash)..<r.lowerBound])
            }
            current = parent
        }
        return nil
    }

    /// The session's own terminal if it is still running, else the last one used, else one that is open, else Terminal.
    private static func terminal(for sessionID: String) -> String {
        if let pid = pid(of: sessionID), let app = ancestorTerminal(of: pid) { return app }
        if let last = UserDefaults.standard.string(forKey: defaultsKey) { return last }
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        return known.first { running.contains($0) } ?? "Terminal"
    }

    private static func pid(of sessionID: String) -> Int32? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["sessionId"] as? String == sessionID, let pid = obj["pid"] as? Int else { continue }
            return Int32(pid)
        }
        return nil
    }

    /// Walks up the process tree until it meets a known terminal app bundle.
    private static func ancestorTerminal(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<12 {
            guard let line = ps(current, field: "ppid=,comm=") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let parent = Int32(parts[0]), parent > 1 else { return nil }
            for name in known where parts[1].contains("/\(name).app/") { return name }
            current = parent
        }
        return nil
    }

    private static func ps(_ pid: Int32, field: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", field.hasSuffix("=") || field.contains(",") ? field : field + "=", "-p", "\(pid)"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Runs AppleScript and returns its result; gives up after 20 s (e.g. an unanswered permission prompt).
    private static func runCapture(_ script: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
