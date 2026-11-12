import AppKit

/// Reopens a Claude Code session in the terminal the user actually uses.
/// macOS has no "default terminal" setting, so we look at where the session ran, then at what is open now.
enum TerminalLauncher {
    private static let known = ["Terminal", "iTerm", "Ghostty", "WezTerm", "Warp", "kitty", "Alacritty", "Hyper", "Tabby", "Rio"]
    private static let defaultsKey = "lastTerminalApp"

    /// Where a message to a session ended up.
    enum SendOutcome {
        case typed(String)     // into the session's own Terminal/iTerm tab
        case forked(String)    // its terminal can't be scripted (Warp, Ghostty, …): a new window continues a copy of it
        case opened(String)    // the session was closed: reopened with the message
        case failed
    }

    /// Hands `text` to a session as the user's next message. Blocks for up to 20 s on AppleScript; call it off the
    /// main thread. A running session in Terminal or iTerm gets it typed into its own tab. Other terminals have no
    /// way to reach one tab, so a new window resumes a fork of the session (`--fork-session`), which leaves the open
    /// tab's conversation intact. A closed session reopens with the text as its first prompt.
    static func send(sessionID: String, cwd: String, text: String) -> SendOutcome {
        let flat = oneLine(text)
        guard isValid(sessionID), !flat.isEmpty else { return .failed }
        guard let pid = pid(of: sessionID), kill(pid, 0) == 0 else {
            return .opened(launch(sessionID: sessionID, cwd: cwd, prompt: flat, fork: false))
        }
        let host = hostApp(of: pid) ?? ""
        if host == "Terminal" || host == "iTerm", let tty = ps(pid, field: "tty"), tty.hasPrefix("ttys"),
           type(flat, into: "/dev/" + tty, host: host) {
            return .typed(host)
        }
        if host == "Warp", WarpTabs.type(flat, sessionID: sessionID, claudePID: pid) { return .typed(host) }
        return .forked(launch(sessionID: sessionID, cwd: cwd, prompt: flat, fork: true))
    }

    private static func isValid(_ id: String) -> Bool {
        id.range(of: #"^[0-9a-fA-F-]{8,64}$"#, options: .regularExpression) != nil
    }

    static func claudePath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The Resume button: brings a running session forward, else reopens it.
    static func resume(sessionID: String, cwd: String) {
        guard isValid(sessionID) else { return }
        if focusRunning(sessionID) { return }
        launch(sessionID: sessionID, cwd: cwd, prompt: nil, fork: false)
    }

    /// Opens `claude --resume` in the user's terminal; returns that terminal's name.
    @discardableResult
    private static func launch(sessionID: String, cwd: String, prompt: String?, fork: Bool) -> String {
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        var command = "cd \(shellQuote(dir)) && claude --resume \(sessionID)"
        if fork { command += " --fork-session" }
        // one line: terminals that type the command would submit at the first newline
        if let prompt, !prompt.isEmpty { command += " " + shellQuote(oneLine(prompt)) }
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
        case "Warp":
            // Warp runs a command only through a launch configuration, opened by its URL scheme
            guard let script = commandFile(sessionID, command) else { break }
            let configs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".warp/launch_configurations")
            let config = configs.appendingPathComponent("leftovers-resume.yaml")
            let yaml = """
            ---
            name: Leftovers
            windows:
              - tabs:
                  - title: Claude
                    layout:
                      cwd: "\(yamlEscape(dir))"
                      commands:
                        - exec: "zsh \(yamlEscape(shellQuote(script.path)))"

            """
            try? FileManager.default.createDirectory(at: configs, withIntermediateDirectories: true)
            guard (try? yaml.write(to: config, atomically: true, encoding: .utf8)) != nil,
                  let url = URL(string: "warp://launch/leftovers-resume.yaml") else { break }
            NSWorkspace.shared.open(url)
            // keep Warp's launch-configuration menu clean once it has read the file
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { try? FileManager.default.removeItem(at: config) }
        default:
            // other terminals open an executable .command script
            guard let file = commandFile(sessionID, command) else { break }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app, file.path]
            try? p.run()
        }
        return app
    }

    private static func commandFile(_ sessionID: String, _ command: String) -> URL? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("leftovers-\(sessionID).command")
        guard (try? "#!/bin/zsh -l\n\(command)\n".write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Types a line into the Terminal/iTerm tab that owns `tty`, presses Return and brings the tab forward.
    /// Claude Code queues a message typed while it is still working.
    private static func type(_ text: String, into tty: String, host: String) -> Bool {
        let t = escapeAS(text)
        let script = host == "iTerm" ? """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select t
                            select s
                            activate
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
                        set selected of t to true
                        set index of w to 1
                        activate
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
        case "Warp" where WarpTabs.type(nil, sessionID: sessionID, claudePID: pid):
            break
        default:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", host]
            try? p.run()
        }
        return true
    }

    /// Parent process id, from `ps`.
    static func parent(of pid: Int32) -> Int32? {
        ps(pid, field: "ppid").flatMap { Int32($0) }
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
        // where the user's other Claude Code sessions run right now
        if let app = livePIDs().lazy.compactMap({ ancestorTerminal(of: $0) }).first { return app }
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        return known.first { running.contains($0) } ?? "Terminal"
    }

    private static func registry() -> [[String: Any]] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static func livePIDs() -> [Int32] {
        registry().compactMap { ($0["pid"] as? Int).map(Int32.init) }.filter { kill($0, 0) == 0 }
    }

    private static func pid(of sessionID: String) -> Int32? {
        registry().first { $0["sessionId"] as? String == sessionID }.flatMap { ($0["pid"] as? Int).map(Int32.init) }
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

    static func ps(_ pid: Int32, field: String) -> String? {
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
    static func runCapture(_ script: String) -> String? {
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

    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    private static func yamlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
