import AppIntents
import SwiftUI
import WidgetKit

struct TodoEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
    let selectedID: String?
    var cardKey: String? = nil
}

/// The reply card: open items that come with an AI-suggested reply, across all tabs, yours first in each tab.
struct ReplyCard {
    let session: TodoSession
    let item: TodoItem
    var key: String { session.id + "|" + item.id }

    /// Tabs the widget shows, in order.
    static func tabs(_ state: WidgetState) -> [TodoSession] {
        state.sessions.filter { $0.openCount > 0 || $0.analyzing || $0.busy }
    }

    static func queue(_ tabs: [TodoSession]) -> [ReplyCard] {
        tabs.filter { $0.id != "manual" }.flatMap { s in
            let open = s.items.filter { $0.status != .completed && !$0.suggestion.isEmpty }
            return (open.filter(\.needsYou) + open.filter { !$0.needsYou }).map { ReplyCard(session: s, item: $0) }
        }
    }

    /// Index of the card to show: the stored one if it belongs to the selected tab, else that tab's first.
    static func current(_ queue: [ReplyCard], selected: String?, stored: String?) -> Int? {
        guard let selected else { return nil }
        if let stored, let i = queue.firstIndex(where: { $0.key == stored }), queue[i].session.id == selected { return i }
        return queue.firstIndex { $0.session.id == selected }
    }
}

/// The widget's ‹ › arrows: move to the previous/next suggested reply, switching tabs when it lives in another one.
struct StepCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Next suggestion"

    @Parameter(title: "Step") var delta: Int

    init() {}
    init(delta: Int) { self.delta = delta }

    func perform() async throws -> some IntentResult {
        guard let state = SharedState.read() else { return .result() }
        let tabs = ReplyCard.tabs(state)
        let queue = ReplyCard.queue(tabs)
        guard !queue.isEmpty else { return .result() }
        let selected = (tabs.first { $0.id == SharedState.readSelection() } ?? tabs.first)?.id
        let next: Int
        if let cur = ReplyCard.current(queue, selected: selected, stored: SharedState.readCard()) {
            next = (cur + delta + queue.count) % queue.count
        } else {
            // the selected tab has no card: jump to the nearest one in that direction
            next = delta > 0 ? 0 : queue.count - 1
        }
        SharedState.writeCard(queue[next].key)
        SharedState.writeSelection(queue[next].session.id)
        return .result()
    }
}

/// Tapping a tab on the widget stores which session to show; WidgetKit reloads the timeline afterwards.
struct SelectSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Select session"

    @Parameter(title: "Session") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        SharedState.writeSelection(sessionID)
        return .result()
    }
}

/// Shared look for the widget and the panel: quiet dark card, one green accent.
enum Look {
    static let bg = LinearGradient(
        colors: [Color(red: 0.10, green: 0.11, blue: 0.12), Color(red: 0.06, green: 0.07, blue: 0.08)],
        startPoint: .top, endPoint: .bottom)
    static let accent = Color(red: 0.36, green: 0.86, blue: 0.56)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.45)
    static let chip = Color.white.opacity(0.07)

    static func symbol(_ item: TodoItem) -> String {
        if item.needsYou { return "hand.raised.circle.fill" }
        return switch item.kind {
        case .todo: "circle"
        case .working: "circle.fill"
        case .offer: "questionmark.circle"
        case .interrupted: "exclamationmark.triangle"
        case .resume: "arrow.uturn.backward.circle"
        }
    }
    static func tint(_ item: TodoItem) -> Color {
        item.needsYou || item.kind == .interrupted || item.status == .inProgress ? amber : accent
    }

    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return Date().timeIntervalSince(date) < 90 ? "just now" : f.localizedString(for: date, relativeTo: Date())
    }

    static func resumeURL(_ id: String) -> URL? {
        URL(string: "claudetodo://resume?id=\(id)")
    }
    /// A tap on a task: the app sends the task to its session.
    static func taskURL(_ sessionID: String, _ itemID: String) -> URL? {
        var c = URLComponents()
        c.scheme = "claudetodo"
        c.host = "task"
        c.queryItems = [URLQueryItem(name: "id", value: sessionID), URLQueryItem(name: "item", value: itemID)]
        return c.url
    }
    static func replyURL(_ card: ReplyCard, edit: Bool) -> URL? {
        var c = URLComponents()
        c.scheme = "claudetodo"
        c.host = "reply"
        c.queryItems = [URLQueryItem(name: "id", value: card.session.id), URLQueryItem(name: "item", value: card.item.id)]
            + (edit ? [URLQueryItem(name: "edit", value: "1")] : [])
        return c.url
    }
}

struct TodoWidgetView: View {
    let entry: TodoEntry
    /// Previews are rendered outside WidgetKit, so they need their own background.
    var preview = false
    /// Set only by previews; inside WidgetKit the family comes from the environment.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    private var tabs: [TodoSession] { ReplyCard.tabs(entry.state) }
    private var selected: TodoSession? { tabs.first { $0.id == entry.selectedID } ?? tabs.first }

    private var tabSlots: Int { family == .systemLarge ? 4 : 3 }
    private var selectedIndex: Int { tabs.firstIndex { $0.id == selected?.id } ?? 0 }
    /// Index of the first visible tab: the window slides so the selected tab is always inside it.
    private var windowStart: Int { max(0, min(selectedIndex - tabSlots + 1, tabs.count - tabSlots)) }
    private var visibleTabs: [TodoSession] { Array(tabs.dropFirst(windowStart).prefix(tabSlots)) }

    private var rowLimit: Int {
        let busy = selected?.busy == true && selected?.nowDoing.isEmpty == false
        if card != nil { return family == .systemLarge ? 3 : 0 }
        return family == .systemLarge ? 5 : family == .systemMedium ? (busy ? 1 : 2) : 3
    }

    private var queue: [ReplyCard] { ReplyCard.queue(tabs) }
    /// The suggested reply shown as a card with Approve / Edit (not on the small widget: no room).
    private var card: (card: ReplyCard, index: Int)? {
        guard family != .systemSmall,
              let i = ReplyCard.current(queue, selected: selected?.id, stored: entry.cardKey) else { return nil }
        return (queue[i], i)
    }

    private var openItems: [TodoItem] {
        guard let s = selected else { return [] }
        let open = s.items.filter { $0.status != .completed }
        return open.filter(\.needsYou) + open.filter { !$0.needsYou }
    }
    /// Rows under the card: everything except the item the card already shows.
    private var rowItems: [TodoItem] { openItems.filter { $0.id != card?.card.item.id } }

    var body: some View {
        board
    }


    @ViewBuilder private var board: some View {
        let content = VStack(spacing: family == .systemMedium ? 5 : 8) {
            if family == .systemSmall { smallLabel } else { tabStrip }
            if !(family == .systemMedium && card != nil) {
                header
                nowLine
            }
            if let card { cardView(card.card, index: card.index) }
            rows
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        if preview { content.padding(14).background(Look.bg) }
        else { content.containerBackground(for: .widget) { Look.bg } }
    }

    /// Centered summary under the tabs.
    private var header: some View {
        let n = selected?.openCount ?? 0
        return HStack(spacing: 5) {
            if !(n == 0 && (selected?.analyzing == true || selected?.busy == true)) { Text(n == 0 ? "All clear" : "\(n)").font(.system(size: family == .systemMedium ? 17 : 20, weight: .bold, design: .rounded)) }
            if n == 0, selected?.analyzing != true, selected?.busy == true { Text("Working…").font(.system(size: 13, weight: .medium)).foregroundStyle(Look.dim) }
            if n == 0, selected?.analyzing == true { Text("Reading session…").font(.system(size: 13, weight: .medium)).foregroundStyle(Look.dim) }
            if n > 0 { Text(youCount > 0 ? "waiting · \(youCount) on you" : "waiting").font(.system(size: 13, weight: .medium)).foregroundStyle(Look.dim) }
        }
        .foregroundStyle(n == 0 ? Look.accent : Look.text)
        .frame(maxWidth: .infinity)
    }

    /// Live activity of a busy session ("Editing TodoPanel.swift").
    @ViewBuilder private var nowLine: some View {
        if let s = selected, s.busy, !s.nowDoing.isEmpty, family != .systemSmall {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Look.amber)
                Text(s.nowDoing).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Look.amber).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var youCount: Int { openItems.filter(\.needsYou).count }

    private var tabStrip: some View {
        HStack(spacing: 5) {
            ForEach(visibleTabs) { session in
                let isSelected = session.id == selected?.id
                Button(intent: SelectSessionIntent(sessionID: session.id)) {
                    HStack(spacing: 4) {
                        if session.id != "manual" { Circle().fill(session.busy ? Look.amber : session.live ? Look.accent : Look.dim).frame(width: 5, height: 5) }
                        Text(session.title).lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    // light text on a translucent pill: stays readable when macOS tints the widget (accented mode)
                    .foregroundStyle(isSelected ? Look.text : Look.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, family == .systemMedium ? 4 : 5)
                    .background(isSelected ? Look.accent.opacity(0.30) : Look.chip, in: Capsule())
                    .overlay(Capsule().strokeBorder(Look.accent.opacity(isSelected ? 0.7 : 0), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if tabs.count > visibleTabs.count {
                // jump to the first hidden tab on the right, or back to the start when none is left
                let after = tabs.count - windowStart - visibleTabs.count
                let target = after > 0 ? tabs[windowStart + visibleTabs.count] : tabs[0]
                Button(intent: SelectSessionIntent(sessionID: target.id)) {
                    Text(after > 0 ? "+\(after)" : "‹")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Look.text)
                        .frame(width: 26).padding(.vertical, 5)
                        .background(Look.chip, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }


    private var smallLabel: some View {
        Text(selected?.title ?? "Leftovers").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Look.dim).lineLimit(1).frame(maxWidth: .infinity)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            ForEach(rowItems.prefix(rowLimit)) { item in
                row(item)
            }
            if rowItems.count > rowLimit, family != .systemMedium {
                Text("+\(rowItems.count - rowLimit) more").font(.system(size: 10)).foregroundStyle(Look.dim)
            }
            if let s = selected, s.id != "manual", family == .systemLarge {
                Text("Updated \(Look.ago(s.updatedAt)) · tap a task to send it")
                    .font(.system(size: 9.5)).foregroundStyle(Look.dim.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func cardView(_ card: ReplyCard, index: Int) -> some View {
        let item = card.item
        let large = family == .systemLarge
        return VStack(alignment: .leading, spacing: large ? 7 : 5) {
            HStack(spacing: 6) {
                Image(systemName: Look.symbol(item)).font(.system(size: 10)).foregroundStyle(Look.tint(item))
                Text(item.content).font(.system(size: 12, weight: .semibold)).foregroundStyle(Look.text).lineLimit(1)
                Spacer(minLength: 4)
                if queue.count > 1 {
                    Text("\(index + 1)/\(queue.count)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Look.dim)
                    stepButton("chevron.left", -1)
                    stepButton("chevron.right", 1)
                }
            }
            // the options the suggestion picks from; without them "Approve" would be a blind click
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: 10.5)).foregroundStyle(Look.dim).lineLimit(large ? 3 : 1)
            }
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Look.accent).padding(.top, 2)
                Text(item.suggestion).font(.system(size: 11)).foregroundStyle(Look.text.opacity(0.88))
                    .lineLimit(large ? 2 : 1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Look.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 6) {
                cardLink("Approve", "checkmark", Look.replyURL(card, edit: false), primary: true)
                cardLink("Edit", "pencil", Look.replyURL(card, edit: true), primary: false)
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(Look.chip, in: RoundedRectangle(cornerRadius: 11))
    }

    private func stepButton(_ symbol: String, _ delta: Int) -> some View {
        Button(intent: StepCardIntent(delta: delta)) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Look.text)
                .frame(width: 20, height: 18)
                .background(Look.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardLink(_ title: String, _ symbol: String, _ url: URL?, primary: Bool) -> some View {
        let label = cardLabel(title, symbol, primary: primary)
        if !preview, let url { Link(destination: url) { label } } else { label }
    }

    private func cardLabel(_ title: String, _ symbol: String, primary: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(primary ? Look.text : Look.dim)
        .padding(.horizontal, 10).padding(.vertical, 4)
        // translucent fill + outline, like the tabs: stays readable when macOS tints the widget
        .background(primary ? Look.accent.opacity(0.30) : Look.chip, in: Capsule())
        .overlay(Capsule().strokeBorder(Look.accent.opacity(primary ? 0.7 : 0), lineWidth: 1))
    }

    @ViewBuilder
    private func row(_ item: TodoItem) -> some View {
        let content = HStack(alignment: .top, spacing: 7) {
            Image(systemName: Look.symbol(item)).font(.system(size: 10))
                .foregroundStyle(Look.tint(item)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.content)
                    .font(.system(size: family == .systemLarge ? 12.5 : 11.5, weight: .semibold))
                    .foregroundStyle(Look.text)
                    .lineLimit(1)
                if family != .systemSmall, !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Look.dim)
                        .lineLimit(family == .systemLarge ? 2 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        let link = selected.flatMap { s in s.id == "manual" ? nil : Look.taskURL(s.id, item.id) }
        if !preview, family != .systemSmall, let url = link {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}
