import AppIntents
import SwiftUI
import WidgetKit

struct TodoEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
    let selectedID: String?
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

    static func resumeURL(_ id: String) -> URL? { URL(string: "claudetodo://resume?id=\(id)") }
}

struct TodoWidgetView: View {
    let entry: TodoEntry
    /// Previews are rendered outside WidgetKit, so they need their own background.
    var preview = false
    /// Set only by previews; inside WidgetKit the family comes from the environment.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    private var tabs: [TodoSession] { entry.state.sessions.filter { $0.openCount > 0 || $0.analyzing } }
    private var selected: TodoSession? { tabs.first { $0.id == entry.selectedID } ?? tabs.first }

    private var tabSlots: Int { family == .systemLarge ? 4 : 3 }
    private var selectedIndex: Int { tabs.firstIndex { $0.id == selected?.id } ?? 0 }
    /// Index of the first visible tab: the window slides so the selected tab is always inside it.
    private var windowStart: Int { max(0, min(selectedIndex - tabSlots + 1, tabs.count - tabSlots)) }
    private var visibleTabs: [TodoSession] { Array(tabs.dropFirst(windowStart).prefix(tabSlots)) }

    private var rowLimit: Int { family == .systemLarge ? 5 : family == .systemMedium ? 2 : 3 }

    private var openItems: [TodoItem] {
        guard let s = selected else { return [] }
        let open = s.items.filter { $0.status != .completed }
        return open.filter(\.needsYou) + open.filter { !$0.needsYou }
    }

    var body: some View {
        let content = VStack(spacing: family == .systemMedium ? 5 : 8) {
            if family == .systemSmall { smallLabel } else { tabStrip }
            header
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
            if !(n == 0 && selected?.analyzing == true) { Text(n == 0 ? "All clear" : "\(n)").font(.system(size: family == .systemMedium ? 17 : 20, weight: .bold, design: .rounded)) }
            if n == 0, selected?.analyzing == true { Text("Reading session…").font(.system(size: 13, weight: .medium)).foregroundStyle(Look.dim) }
            if n > 0 { Text(youCount > 0 ? "waiting · \(youCount) on you" : "waiting").font(.system(size: 13, weight: .medium)).foregroundStyle(Look.dim) }
        }
        .foregroundStyle(n == 0 ? Look.accent : Look.text)
        .frame(maxWidth: .infinity)
    }

    private var youCount: Int { openItems.filter(\.needsYou).count }

    private var tabStrip: some View {
        HStack(spacing: 5) {
            ForEach(visibleTabs) { session in
                let isSelected = session.id == selected?.id
                Button(intent: SelectSessionIntent(sessionID: session.id)) {
                    HStack(spacing: 4) {
                        if session.id != "manual" { Circle().fill(isSelected ? Color.black.opacity(0.55) : session.live ? Look.accent : Look.dim).frame(width: 5, height: 5) }
                        Text(session.title).lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.85) : Look.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, family == .systemMedium ? 4 : 5)
                    .background(isSelected ? Look.accent : Look.chip, in: Capsule())
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
        Text(selected?.title ?? "Claude To-Do").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Look.dim).lineLimit(1).frame(maxWidth: .infinity)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            ForEach(openItems.prefix(rowLimit)) { item in
                row(item)
            }
            if openItems.count > rowLimit, family != .systemMedium {
                Text("+\(openItems.count - rowLimit) more").font(.system(size: 10)).foregroundStyle(Look.dim)
            }
            if let s = selected, s.id != "manual", family == .systemLarge {
                Text("Updated \(Look.ago(s.updatedAt)) · tap a task to resume")
                    .font(.system(size: 9.5)).foregroundStyle(Look.dim.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
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
        if let s = selected, s.id != "manual", family != .systemSmall, let url = Look.resumeURL(s.id) {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}
