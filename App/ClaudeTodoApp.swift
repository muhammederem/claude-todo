import SwiftUI
import WidgetKit

@main
struct ClaudeTodoApp: App {
    @NSApplicationDelegateAdaptor(URLHandler.self) private var urlHandler
    @StateObject private var store = TodoStore()

    init() {
        let args = CommandLine.arguments
        if args.contains("--dump") { TodoStore.dumpSync() }
        if let i = args.firstIndex(of: "--snapshot-widget"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.writeWidgets(to: args[i + 1]) }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.write(to: args[i + 1]) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            TodoPanel(store: store)
                .frame(width: 320, height: 420)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `--snapshot out.png`: render the panel to an image and exit (design check without opening the UI).
@MainActor
enum Snapshot {
    /// `--snapshot-widget out.png`: the three widget sizes with real data, side by side.
    static func writeWidgets(to path: String) {
        let demo = CommandLine.arguments.contains("--demo")
        let state = demo ? .sample : (SharedState.read() ?? .sample)
        let entry = TodoEntry(date: Date(timeIntervalSinceReferenceDate: 800_000_000), state: state, selectedID: nil)
        func card(_ family: WidgetFamily, _ w: CGFloat, _ h: CGFloat) -> some View {
            TodoWidgetView(entry: entry, preview: true, familyOverride: family)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        let content = HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) { card(.systemSmall, 170, 170); card(.systemMedium, 364, 170) }
            card(.systemLarge, 364, 354)
        }
        .padding(16).background(Color(white: 0.25))
        render(content, to: path)
    }

    private static func render<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("snapshot failed"); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    static func write(to path: String) {
        let store = TodoStore(autoRefresh: false)
        if CommandLine.arguments.contains("--demo") { store.loadDemo() } else { store.refreshNow() }
        let content = VStack(spacing: 8) {
            MenuBarLabel(store: store)
            TodoPanel(store: store, preview: true).frame(width: 320, height: 420)
        }
        .padding(8).background(Color(white: 0.2))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("snapshot failed"); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}

/// Widget links: `claudetodo://resume?id=<sessionId>` reopens a session; `claudetodo://reply?id=…&item=…`
/// sends the item's suggested reply, and with `&edit=1` opens it for editing first.
final class URLHandler: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "claudetodo" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            guard let id = value("id") else { continue }
            let session = SharedState.read()?.sessions.first { $0.id == id }
            switch url.host {
            case "resume":
                TodoStore.resume(sessionID: id, cwd: session?.cwd ?? "")
            case "reply":
                guard let session, let item = session.items.first(where: { $0.id == value("item") }) else { continue }
                MainActor.assumeIsolated {
                    if value("edit") == "1" || item.suggestion.isEmpty { ReplyPanel.show(session: session, item: item) }
                    else { Reply.send(session: session, text: item.suggestion) }
                }
            default:
                continue
            }
        }
    }
}
