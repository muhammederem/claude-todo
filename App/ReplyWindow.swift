import AppKit
import SwiftUI
import UserNotifications

/// Sends an AI-suggested (or edited) reply to a session and tells the user what happened.
enum Reply {
    @MainActor
    static func send(session: TodoSession, text: String) {
        switch TerminalLauncher.reply(sessionID: session.id, cwd: session.cwd, text: text) {
        case .copied:
            notify("Reply copied · \(session.title)", "The session is still open: paste with ⌘V and press Return.")
        case .sent, .failed:
            break
        }
    }

    private static func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Small floating window to review and edit a suggested reply before it goes to the session.
/// The menu bar panel cannot be opened from code, so the widget's "Edit" lands here.
final class ReplyPanel: NSPanel {
    private static var current: ReplyPanel?

    @MainActor
    static func show(session: TodoSession, item: TodoItem) {
        current?.close()
        let panel = ReplyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Reply · \(session.title)"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: ReplyView(session: session, item: item) { panel.close() })
        panel.center()
        current = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }
}

struct ReplyView: View {
    let session: TodoSession
    let item: TodoItem
    let close: () -> Void
    @State private var text: String
    private let running: Bool

    init(session: TodoSession, item: TodoItem, close: @escaping () -> Void) {
        self.session = session
        self.item = item
        self.close = close
        _text = State(initialValue: item.suggestion)
        running = TerminalLauncher.isRunning(session.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Look.symbol(item)).foregroundStyle(Look.tint(item)).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.content).font(.system(size: 13, weight: .semibold)).foregroundStyle(Look.text)
                    if !item.detail.isEmpty { Text(item.detail).font(.system(size: 11.5)).foregroundStyle(Look.dim) }
                }
            }
            if !session.lastReply.isEmpty {
                Text("Claude's last message").font(.system(size: 10, weight: .semibold)).foregroundStyle(Look.dim)
                ScrollView {
                    Text(session.lastReply).font(.system(size: 11.5)).foregroundStyle(Look.text.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .padding(8)
                .frame(maxHeight: 150)
                .background(Look.chip, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Your reply").font(.system(size: 10, weight: .semibold)).foregroundStyle(Look.dim)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Look.chip, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 70)
            Text(running ? "The session is open: the reply is copied and its terminal comes to the front."
                         : "The session is closed: it reopens in your terminal with this reply.")
                .font(.system(size: 10.5)).foregroundStyle(Look.dim)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(running ? "Copy & open" : "Send") {
                    Reply.send(session: session, text: text)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 30)
        .frame(width: 440)
        .background(Look.bg)
        .environment(\.colorScheme, .dark)
    }
}
