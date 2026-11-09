import SwiftUI

struct TodoPanel: View {
    @ObservedObject var store: TodoStore
    /// ImageRenderer can't draw ScrollView/TextField, so snapshots swap in plain stand-ins.
    var preview = false
    @State private var draft = ""
    @State private var loginOn = Notifier.launchesAtLogin
    @State private var swipe = SwipeTracker()

    private let tr = Locale(identifier: "tr_TR")

    var body: some View {
        VStack(spacing: 10) {
            tabs
            if let session = store.selected { list(session) }
            if let problem = store.summaryProblem {
                Text(problem).font(.system(size: 10.5)).foregroundStyle(Look.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            input
            footer
        }
        .padding(12)
        .frame(minWidth: 280, minHeight: 240)
        .background(Look.bg)
        .environment(\.colorScheme, .dark)
        .onAppear { if !preview { swipe.start(store) } }
        .onDisappear { swipe.stop() }
    }

    @ViewBuilder
    private func scroll<C: View>(_ axes: Axis.Set, @ViewBuilder _ content: () -> C) -> some View {
        if preview { content() } else { ScrollView(axes, showsIndicators: false) { content() } }
    }

    // MARK: Tabs

    /// One row of tabs; swipe to scroll, or use the arrows, which also move the selection.
    private var tabs: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 4) {
                if !preview { arrow("chevron.left") { step(-1, proxy) } }
                scroll(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(previewTabs) { session in
                            let isSelected = session.id == store.selected?.id
                            Button { store.selectedID = session.id } label: {
                                HStack(spacing: 5) {
                                    if session.id != TodoStore.manualID {
                                        Circle().fill(isSelected ? Color.black.opacity(0.55) : session.busy ? Look.amber : session.live ? Look.accent : Look.dim)
                                            .frame(width: 6, height: 6)
                                    }
                                    Text(session.title).lineLimit(1)
                                    if session.analyzing { Text("…") }
                                    else if session.openCount > 0 { Text("\(session.openCount)").opacity(0.7) }
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.black.opacity(0.85) : Look.dim)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(isSelected ? Look.accent : Look.chip, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .id(session.id)
                            .help(session.cwd)
                        }
                    }
                }
                if !preview { arrow("chevron.right") { step(1, proxy) } }
            }
            .onChange(of: store.selected?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// ImageRenderer cannot scroll, so a preview shows only the tabs that fit.
    private var previewTabs: [TodoSession] {
        preview ? Array(store.sessions.filter { $0.id != TodoStore.manualID }.prefix(3)) : store.sessions
    }

    private func arrow(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .bold)).foregroundStyle(Look.dim)
                .frame(width: 18, height: 24)
        }
        .buttonStyle(.plain)
    }

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        store.step(delta)
        if let next = store.selectedID { withAnimation { proxy.scrollTo(next, anchor: .center) } }
    }

    // MARK: List

    private func list(_ session: TodoSession) -> some View {
        let isManual = session.id == TodoStore.manualID
        let n = session.openCount
        return scroll(.vertical) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    Spacer()
                    Text(n == 0 ? "All clear" : "\(n)").font(.system(size: 20, weight: .bold, design: .rounded))
                    if n > 0 { Text("waiting").font(.system(size: 13, weight: .medium)).foregroundStyle(Look.dim) }
                    Spacer()
                }
                .foregroundStyle(n == 0 ? Look.accent : Look.text)
                if !isManual { sessionHeader(session) }
                if session.busy, !session.nowDoing.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Look.amber)
                        Text(session.nowDoing).font(.system(size: 12, weight: .medium)).foregroundStyle(Look.amber).lineLimit(2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Look.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if session.items.isEmpty {
                    Text(isManual ? "Nothing yet. Add a task below." : session.analyzing ? "Reading session…" : session.busy ? "Working, nothing waiting on you yet" : "Nothing waiting")
                        .font(.system(size: 12)).foregroundStyle(Look.dim)
                        .padding(.top, 14).frame(maxWidth: .infinity)
                }
                ForEach(session.items) { item in row(item, manual: isManual) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: preview ? .infinity : nil, alignment: .topLeading)
        }
        .background(Look.chip, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sessionHeader(_ session: TodoSession) -> some View {
        let state = session.busy ? "Working" : session.live ? "Open" : "Closed"
        return HStack(spacing: 10) {
            Text("\(state) · \(Look.ago(session.updatedAt))").font(.system(size: 10, weight: .semibold)).foregroundStyle(Look.dim)
            Spacer()
            Button { TodoStore.resume(sessionID: session.id, cwd: session.cwd) } label: {
                Text("Resume").font(.system(size: 10, weight: .semibold)).foregroundStyle(Look.accent)
            }
            .buttonStyle(.plain)
            .help("Open this session in Terminal")
            Button { store.dismiss(session) } label: {
                Text("Hide").font(.system(size: 10, weight: .semibold)).foregroundStyle(Look.dim)
            }
            .buttonStyle(.plain)
            .help("Hide this tab until the session becomes active again")
        }
    }

    private func row(_ item: TodoItem, manual: Bool) -> some View {
        let done = item.status == .completed
        let tint: Color = done ? Look.dim : Look.tint(item)
        return HStack(alignment: .top, spacing: 8) {
            Button { if manual { store.cycle(item) } } label: {
                Image(systemName: done ? "checkmark.circle.fill" : Look.symbol(item))
                    .font(.system(size: 12)).foregroundStyle(tint).padding(.top, 1)
            }
            .buttonStyle(.plain)
            .disabled(!manual)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.status == .inProgress ? item.activeForm : item.content)
                    .font(.system(size: 12.5, weight: item.detail.isEmpty ? .regular : .semibold))
                    .foregroundStyle(done ? Look.dim : Look.text)
                    .strikethrough(done)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(Look.dim)
                }
                if !manual, !done, !item.suggestion.isEmpty, let session = store.selected { suggestion(item, in: session) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { if manual { store.deleteManual(item) } else if let s = store.selected { store.finish(item, in: s) } } label: {
                Image(systemName: manual ? "xmark" : "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Look.dim)
            }
            .buttonStyle(.plain)
            .help(manual ? "Delete" : "Mark as done")
        }
    }

    /// The AI-suggested reply with Approve (send as is) and Edit (review it in a small window first).
    private func suggestion(_ item: TodoItem, in session: TodoSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Look.accent).padding(.top, 2)
                Text(item.suggestion).font(.system(size: 11.5)).foregroundStyle(Look.text.opacity(0.88))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Look.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 6) {
                Button { Reply.send(session: session, text: item.suggestion) } label: {
                    Label("Approve", systemImage: "checkmark").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Look.text)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Look.accent.opacity(0.30), in: Capsule())
                        .overlay(Capsule().strokeBorder(Look.accent.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(session.live ? "Copy this reply and bring the session's terminal forward" : "Reopen the session with this reply")
                Button { ReplyPanel.show(session: session, item: item) } label: {
                    Label("Edit", systemImage: "pencil").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Look.dim)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Look.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Change the reply before sending it")
            }
        }
        .padding(.top, 3)
    }

    // MARK: Input & footer

    private var input: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Look.accent)
            if preview {
                Text("New task…").font(.system(size: 12.5)).foregroundStyle(Look.dim)
                Spacer()
            } else {
                TextField("New task…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit { store.addManual(draft); draft = "" }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Look.chip, in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            if store.selected?.id == TodoStore.manualID, store.manual.contains(where: { $0.status == .completed }) {
                footerButton("Clear done") { store.clearCompletedManual() }
            }
            footerButton(store.smartSummary ? "AI: on" : "AI: off") { store.smartSummary.toggle() }
                .help("When on, idle sessions are summarized with claude -p (Haiku); each one is a small API call")
            if store.hiddenCount > 0 {
                footerButton("Restore hidden (\(store.hiddenCount))") { store.restoreHidden() }
                    .help("Show hidden tabs and tasks again")
            }
            if store.smartSummary { footerButton("↻") { store.reanalyze() }.help("Re-analyze all") }
            footerButton(store.iphoneSync ? "iPhone: on" : "iPhone: off") { store.iphoneSync.toggle() }
                .help("Show this board on the Claude To-Do iPhone app through your iCloud, and take replies sent from it")
            footerButton(loginOn ? "Login: on" : "Login: off") { Notifier.setLaunchAtLogin(!loginOn); loginOn = Notifier.launchesAtLogin }
                .help("Start Claude To-Do when you log in")
            footerButton("Quit") { NSApp.terminate(nil) }
        }
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Look.dim)
    }
}

/// Two-finger horizontal swipe on the panel moves to the previous/next tab (the tab row itself keeps scrolling).
@MainActor
final class SwipeTracker {
    private var monitor: Any?
    private var sum: CGFloat = 0
    private var fired = false
    /// Height of the tab row from the top of the panel; swipes there scroll the tabs instead.
    private let tabRow: CGFloat = 44

    func start(_ store: TodoStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak store] event in
            guard let self, let store, event.hasPreciseScrollingDeltas, !(event.window is ReplyPanel) else { return event }
            if event.phase == .began { sum = 0; fired = false }
            guard event.phase == .began || event.phase == .changed, !fired,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            if let height = event.window?.contentView?.bounds.height, height - event.locationInWindow.y < tabRow { return event }
            sum += event.scrollingDeltaX
            if abs(sum) > 50 {
                fired = true
                store.step(sum < 0 ? 1 : -1)   // content follows the fingers: swipe left shows the next tab
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Left-to-right layout that starts a new line when the next item does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 280, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), origins)
    }
}
