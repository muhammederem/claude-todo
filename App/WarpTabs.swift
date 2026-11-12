import AppKit
import Darwin

/// Types into the Warp tab that runs a given Claude Code session. Warp has no scripting interface, so this
///   1. finds the tab: the session's shell is one of the shells Warp's terminal server started; among the shells in the
///      same folder, its rank by pid matches its rank among the tabs Warp's own state database lists for that folder;
///   2. switches to it with ⌘<number> through System Events (needs the Accessibility permission);
///   3. checks that the window title now shows the session's title, which Claude Code sets as the terminal title,
///      and only then pastes the text and presses Return.
/// Anything uncertain returns false and the caller falls back to a new window, so text never lands in the wrong tab.
enum WarpTabs {
    private static let bundleID = "dev.warp.Warp-Stable"
    private static var database: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }

    /// `text` nil only brings the tab forward (Resume).
    static func type(_ text: String?, sessionID: String, claudePID: Int32) -> Bool {
        guard let title = sessionTitle(sessionID), let shell = TerminalLauncher.parent(of: claudePID),
              let tab = tabNumber(shell: shell), tab <= 8 else { return false }
        return type(text, tab: tab, title: title)
    }

    /// Switches to tab `tab` of whichever Warp window then shows `title`, and pastes `text` there with Return.
    static func type(_ text: String?, tab: Int, title: String) -> Bool {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return false }

        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        if let text {
            board.clearContents()
            board.setString(text, forType: .string)
        }
        defer {
            if text != nil {
                // give Warp a moment to read the paste before the old clipboard comes back
                Thread.sleep(forTimeInterval: 0.5)
                board.clearContents()
                if let saved { board.setString(saved, forType: .string) }
            }
        }

        // the title Claude Code sets can be cut short by the terminal; match on its start
        let wanted = TerminalLauncher.escapeAS(String(title.prefix(30)))
        let script = """
        tell application id "\(bundleID)" to activate
        delay 0.2
        tell application "System Events"
            set p to first process whose bundle identifier is "\(bundleID)"
            set found to false
            repeat with w in windows of p
                if name of w contains "\(wanted)" then
                    perform action "AXRaise" of w
                    set found to true
                    exit repeat
                end if
            end repeat
            if not found then
                repeat with w in windows of p
                    perform action "AXRaise" of w
                    delay 0.2
                    keystroke "\(tab)" using command down
                    delay 0.5
                    if name of window 1 of p contains "\(wanted)" then
                        set found to true
                        exit repeat
                    end if
                end repeat
            end if
            if not found then return "missing"
            \(text == nil ? "" : "delay 0.2\n        keystroke \"v\" using command down\n        delay 0.4\n        key code 36")
        end tell
        return "ok"
        """
        return TerminalLauncher.runCapture(script) == "ok"
    }

    /// The session's current title (a `/rename` wins over the generated one), from the end of its transcript.
    static func sessionTitle(_ sessionID: String) -> String? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        guard let file = dirs.map({ $0.appendingPathComponent(sessionID + ".jsonl") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // titles are rewritten as the conversation goes on, so the last one is near the end
        for window in [UInt64(1 << 20), size] {
            try? handle.seek(toOffset: size > window ? size - window : 0)
            let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            for key in ["customTitle", "aiTitle"] {
                if let title = lastValue(of: key, in: tail) { return title }
            }
            if window >= size { break }
        }
        return nil
    }

    private static func lastValue(of key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\":\"((?:[^\"\\\\]|\\\\.)*)\"") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        let raw = "\"" + text[r] + "\""
        let decoded = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? String(text[r])
        return decoded.isEmpty ? nil : decoded
    }

    /// 1-based position of the session's tab within its Warp window.
    static func tabNumber(shell: Int32) -> Int? {
        guard let server = TerminalLauncher.parent(of: shell), let folder = cwd(of: shell) else { return nil }
        let siblings = children(of: server).filter { cwd(of: $0) == folder }.sorted()
        guard let rank = siblings.firstIndex(of: shell) else { return nil }
        let tabs = warpTabs()
        let matching = tabs.filter { $0.folders.contains(folder) }
        guard rank < matching.count else { return nil }
        let target = matching[rank]
        return tabs.filter { $0.window == target.window }.firstIndex { $0.id == target.id }.map { $0 + 1 }
    }

    private struct Tab { let window: Int; let id: Int; var folders: Set<String> }

    /// Tabs in Warp's saved order, each with the folders of its terminal panes.
    private static func warpTabs() -> [Tab] {
        guard FileManager.default.fileExists(atPath: database) else { return [] }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-separator", "\u{1f}", "-newline", "\u{1e}", "file:\(database)?mode=ro",
                       "select t.window_id, t.id, coalesce(tp.cwd, '') from tabs t join pane_nodes n on n.tab_id = t.id "
                       + "join terminal_panes tp on tp.id = n.id order by t.window_id, t.id, n.id"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var tabs: [Tab] = []
        for row in String(decoding: data, as: UTF8.self).split(separator: "\u{1e}") {
            let f = row.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let window = Int(f[0]), let id = Int(f[1]) else { continue }
            let folder = canonical(f[2])
            if let last = tabs.indices.last, tabs[last].id == id {
                tabs[last].folders.insert(folder)
            } else {
                tabs.append(Tab(window: window, id: id, folders: [folder]))
            }
        }
        return tabs
    }

    private static func children(of pid: Int32) -> [Int32] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ax", "-o", "pid=,ppid="]
        p.standardOutput = out
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count == 2, let child = Int32(f[0]), Int32(f[1]) == pid else { return nil }
            return child
        }
    }

    private static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : canonical(path)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
