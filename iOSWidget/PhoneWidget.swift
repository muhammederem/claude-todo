import SwiftUI
import WidgetKit

struct PhoneProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodoEntry { TodoEntry(date: .now, state: .sample, selectedID: nil) }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    /// Pulls the latest board from iCloud (the app may not have run lately), then falls back to the last copy.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        Task {
            if let snap = try? await Cloud.fetchSnapshot() { SharedState.write(snap.state) }
            completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    private func entry() -> TodoEntry {
        TodoEntry(date: .now, state: SharedState.read() ?? .empty, selectedID: SharedState.readSelection(),
                  cardKey: SharedState.readCard(), sent: SharedState.readSent())
    }
}

@main
struct ClaudeTodoPhoneWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeTodoPhoneWidget", provider: PhoneProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude To-Do")
        .description("What your Claude Code sessions on the Mac are waiting for, with suggested replies.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}
