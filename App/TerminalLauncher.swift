import AppKit

/// Reopens a Claude Code session in the terminal the user actually uses.
/// macOS has no "default terminal" setting, so we look at where the session ran, then at what is open now.
enum TerminalLauncher {
    private static let known = ["Terminal", "iTerm", "Ghostty", "WezTerm", "Warp", "kitty", "Alacritty", "Hyper", "Tabby", "Rio"]
    private static let defaultsKey = "lastTerminalApp"

    static func resume(sessionID: String, cwd: String) {
        guard sessionID.range(of: #"^[0-9a-fA-F-]{8,64}$"#, options: .regularExpression) != nil else { return }
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        let command = "cd \(shellQuote(dir)) && claude --resume \(sessionID)"
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
            guard let line = ps(current) else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let parent = Int32(parts[0]), parent > 1 else { return nil }
            for name in known where parts[1].contains("/\(name).app/") { return name }
            current = parent
        }
        return nil
    }

    private static func ps(_ pid: Int32) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "ppid=,comm=", "-p", "\(pid)"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
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
