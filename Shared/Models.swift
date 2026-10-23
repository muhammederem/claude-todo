import Foundation

enum TodoStatus: String, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
}

/// Where an item came from; drives the little marker shown before its text.
enum ItemKind: String, Codable {
    case todo          // a real TodoWrite entry, or something the user typed
    case working       // what a busy session is doing right now
    case offer         // Claude asked or offered something and is waiting for an answer
    case interrupted   // the session stopped mid-task (tool call or API error)
    case resume        // session closed: "this is where we stopped"

    /// Prefix used in LED text (the dot-matrix font only has a few symbols).
    var marker: String {
        switch self {
        case .todo: ""
        case .working: ">"
        case .offer: "?"
        case .interrupted: "!"
        case .resume: "<"
        }
    }
}

struct TodoItem: Identifiable, Hashable, Codable {
    let id: String
    let content: String
    let activeForm: String
    let status: TodoStatus
    var kind: ItemKind = .todo
    /// One-line explanation shown under the title (filled by the smart summary).
    var detail = ""
    /// Waiting on the user (approval, decision, action) rather than on Claude.
    var needsYou = false
}

extension TodoItem {
    // Older state.json files lack `kind`; decoding must not fail on them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        activeForm = try c.decodeIfPresent(String.self, forKey: .activeForm) ?? content
        status = try c.decode(TodoStatus.self, forKey: .status)
        kind = try c.decodeIfPresent(ItemKind.self, forKey: .kind) ?? .todo
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        needsYou = try c.decodeIfPresent(Bool.self, forKey: .needsYou) ?? false
    }
}

struct TodoSession: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var cwd: String
    var items: [TodoItem]
    var updatedAt: Date
    /// Items were inferred from the conversation rather than taken from a TodoWrite list.
    var auto = false
    var analyzing = false
    /// The Claude Code process is still running (false = the session was closed).
    var live = true
    var busy = false
    var lastPrompt = ""

    var openCount: Int { items.filter { $0.status != .completed }.count }
    var doneCount: Int { items.count - openCount }
}

extension TodoSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        items = try c.decode([TodoItem].self, forKey: .items)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        analyzing = try c.decodeIfPresent(Bool.self, forKey: .analyzing) ?? false
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? true
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        lastPrompt = try c.decodeIfPresent(String.self, forKey: .lastPrompt) ?? ""
    }
}

/// A task the user typed in themselves; persisted by TodoStore.
struct ManualTask: Codable, Identifiable {
    let id: UUID
    var text: String
    var status: TodoStatus
}
