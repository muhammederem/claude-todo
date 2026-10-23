import Foundation

/// What a session's last turn looked like; input for the rule-based "what is left" extraction.
struct TurnInfo {
    var firstPrompt = ""
    var lastPrompt = ""
    var lastAssistant = ""
    var stopReason: String?
    var todos: [TodoItem]?
}

/// Finds unfinished work in a conversation without calling any model: a real TodoWrite list wins,
/// otherwise we look for what Claude left hanging (offers, questions, unchecked boxes, interruptions).
enum OpenWork {
    static let maxItems = 3

    static func items(for turn: TurnInfo, live: Bool, busy: Bool) -> [TodoItem] {
        var out: [TodoItem] = []
        func add(_ text: String, _ kind: ItemKind, _ status: TodoStatus = .pending) {
            let t = shorten(text)
            guard t.count >= 6, !out.contains(where: { same($0.content, t) }) else { return }
            out.append(TodoItem(id: "\(kind.rawValue)-\(out.count)", content: t, activeForm: t, status: status, kind: kind))
        }

        if let todos = turn.todos?.filter({ $0.status != .completed }), !todos.isEmpty {
            // an explicit list is authoritative; no guessing on top of it
            return Array(todos.prefix(maxItems + 1))
        }

        let text = clean(turn.lastAssistant)
        let interrupted = turn.lastAssistant.hasPrefix("API Error") || (turn.stopReason == "tool_use" && !busy)
        if interrupted, live { add(turn.lastPrompt, .interrupted) }
        for item in checkboxes(in: text) { add(headline(item), .offer) }
        for item in listedNext(in: text) { add(headline(item), .offer) }
        for item in offers(in: text) { add(item, .offer) }

        if !live, !turn.lastPrompt.isEmpty {
            let resume = (interrupted ? "Interrupted: " : "Left off: ") + shorten(turn.lastPrompt, 56)
            out.insert(TodoItem(id: "resume-0", content: resume, activeForm: resume, status: .pending, kind: .resume), at: 0)
        }
        return Array(out.prefix(maxItems))
    }

    // MARK: Rules

    /// `- [ ] something` left unchecked.
    private static func checkboxes(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            for p in ["- [ ] ", "* [ ] ", "[ ] "] where l.hasPrefix(p) { return String(l.dropFirst(p.count)) }
            return nil
        }
    }

    /// Bullets under a heading such as "Next steps" / "Sıradaki" / "Kalan".
    private static func listedNext(in text: String) -> [String] {
        let heading = try! NSRegularExpression(
            pattern: #"^(?:#+\s*)?(?:sıradaki|siradaki|kalan|kalanlar|yapılacak|yapilacak|sonraki adım|next steps?|remaining|todo|to-do|still to do|open items)\b.*:?\s*$"#,
            options: [.caseInsensitive])
        var out: [String] = [], inList = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { inList = true; continue }
            guard inList else { continue }
            if line.isEmpty { if !out.isEmpty { break } else { continue } }
            guard let item = bulletBody(line) else { break }
            out.append(item)
            if out.count == 3 { break }
        }
        return out
    }

    /// Sentences near the end of the answer that ask or offer something and wait for the user.
    private static func offers(in text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tail = paragraphs.suffix(2).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        let trigger = try! NSRegularExpression(
            pattern: #"\b(istersen|ister misin|onaylarsan|onay(ını|ini)? bekl|devam edeyim|hazırlarım|hazirlarim|seçersen|karar ver|would you like|want me to|shall i|should i|do you want|let me know|if you want|if you'd like|waiting (on|for) you)\b"#,
            options: [.caseInsensitive])
        var out: [String] = []
        for sentence in sentences(tail) {
            let asks = sentence.hasSuffix("?")
            let offers = trigger.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil
            guard asks || offers, sentence.count >= 12, !sentence.contains("://") else { continue }
            out.append(sentence)
        }
        return Array(out.suffix(1))   // the last one are what is actually pending
    }

    // MARK: Text helpers

    private static func sentences(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            // "dashboard.ngrok.com" or "5050/?" must not end a sentence: require whitespace (or the end) after it
            if ".?!".contains(ch), i + 1 == chars.count || chars[i + 1] == " " {
                out.append(trimNoise(cur)); cur = ""
            }
        }
        if !trimNoise(cur).isEmpty { out.append(trimNoise(cur)) }
        return out
    }

    /// "Sabit ngrok adresi. dashboard.ngrok.com → ..." -> "Sabit ngrok adresi"
    private static func headline(_ s: String) -> String {
        var cut = s.endIndex
        for sep in [". ", " — ", " – ", " → ", ": ", " ("] {
            if let r = s.range(of: sep), r.lowerBound < cut, s.distance(from: s.startIndex, to: r.lowerBound) >= 8 { cut = r.lowerBound }
        }
        return trimNoise(String(s[..<cut]))
    }

    /// Leading quotes/dashes and surrounding blanks are noise from markdown or quoting.
    private static func trimNoise(_ s: String) -> String {
        var t = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        while let f = t.first, !(f.isLetter || f.isNumber) { t = t.dropFirst() }
        return String(t)
    }

    private static func bulletBody(_ line: String) -> String? {
        let r = try! NSRegularExpression(pattern: #"^(?:[-*•]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+)$"#)
        guard let m = r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    /// Strips code blocks and markdown decoration so sentences read as plain text.
    static func clean(_ s: String) -> String {
        var out = ""
        var inCode = false
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if !inCode { out += line + "\n" }
        }
        return out.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "__", with: "")
    }

    static func shorten(_ s: String, _ limit: Int = 72) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard one.count > limit else { return one }
        let cut = one.prefix(limit)
        let base = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return base + "…"
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if norm(a) == norm(b) { return true }
        // fuzzy: most words shared => the same thing said twice
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map { String($0.prefix(5)) }) }
        let wa = words(a), wb = words(b)
        guard min(wa.count, wb.count) > 0 else { return false }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= 0.6
    }
}
