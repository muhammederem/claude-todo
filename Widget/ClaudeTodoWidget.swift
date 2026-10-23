import SwiftUI
import WidgetKit

struct TodoProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodoEntry { TodoEntry(date: .now, state: .sample, selectedID: nil) }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        // A single entry: a tab tap reloads the timeline, and one entry renders far faster than a long list.
        // The app also calls reloadAllTimelines() whenever the data changes.
        completion(Timeline(entries: [entry(at: .now)], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func entry(at date: Date) -> TodoEntry {
        TodoEntry(date: date, state: SharedState.read() ?? .empty, selectedID: SharedState.readSelection())
    }
}

@main
struct ClaudeTodoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeTodoWidget", provider: TodoProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude To-Do")
        .description("What is still unfinished in your Claude Code sessions, one tab per session.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
