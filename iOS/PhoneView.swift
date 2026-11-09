import SwiftUI

/// The app is only the widget's companion: setup, connection status, and the reply editor the widget opens.
struct PhoneView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    status(ok: store.iCloudOK, "iCloud", store.iCloudOK ? "Signed in" : "Sign in to iCloud in Settings")
                    status(ok: !store.macAsleep, "Mac",
                           store.macSeen.map { store.macAsleep ? "Last seen \(Look.ago($0)); replies wait until it wakes" : "Online · updated \(Look.ago($0))" }
                           ?? "Turn on \"iPhone: on\" in the Mac app's menu bar panel")
                    status(ok: store.notificationsOK, "Notifications",
                           store.notificationsOK ? "On: approve or reply right from the alert" : "Off: allow them in Settings")
                    if !store.notificationsOK {
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    }
                } header: { Text("Connection") }

                Section {
                    step(1, "Touch and hold an empty spot on the Home Screen, then tap Edit › Add Widget.")
                    step(2, "Find Claude To-Do and pick the medium or large size: they show the suggested reply with Approve and Edit.")
                    step(3, "Use ‹ › on the widget to move between suggestions. Approve sends it to your Mac; Edit or a tap on a task opens a reply box.")
                    step(4, "For the Lock Screen, add the small Claude To-Do widget there too.")
                } header: { Text("Add the widget") }

                if !store.replies.isEmpty {
                    Section {
                        ForEach(store.replies.prefix(8)) { ReplyRow(reply: $0) }
                    } header: { Text("Sent from iPhone") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Look.bg.ignoresSafeArea())
            .navigationTitle("Claude To-Do")
            .refreshable { await store.refresh() }
            .sheet(item: $store.editing) { target in
                EditReplySheet(store: store, target: target)
            }
            .overlay(alignment: .bottom) { toast }
        }
        .preferredColorScheme(.dark)
        .tint(Look.accent)
    }

    private func status(ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Look.accent : Look.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Look.dim)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                .frame(width: 22, height: 22).background(Look.accent, in: Circle())
            Text(text).font(.system(size: 14))
        }
    }

    @ViewBuilder private var toast: some View {
        if let message = store.message {
            Text(message)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Look.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
                .onTapGesture { store.message = nil }
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.message == message { store.message = nil }
                }
        }
    }
}

struct ReplyRow: View {
    let reply: PhoneReply

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(reply.text).font(.system(size: 14)).foregroundStyle(Look.text).lineLimit(3)
                Text([status, Look.ago(reply.created)].joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Look.dim)
            }
        }
    }

    private var status: String {
        switch reply.status {
        case .pending: "Waiting for your Mac"
        case .waiting, .delivered, .failed: reply.note.isEmpty ? reply.status.rawValue.capitalized : reply.note
        }
    }
    private var icon: String {
        switch reply.status {
        case .pending: "clock"
        case .waiting: "hourglass"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch reply.status {
        case .delivered: Look.accent
        case .failed: .red
        default: Look.amber
        }
    }
}

/// Review and change a reply before it goes to the Mac; shows what Claude actually said.
struct EditReplySheet: View {
    @ObservedObject var store: PhoneStore
    let target: PhoneStore.ReplyTarget
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(store: PhoneStore, target: PhoneStore.ReplyTarget) {
        self.store = store
        self.target = target
        _text = State(initialValue: target.item?.suggestion ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let item = target.item {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.content).font(.headline).foregroundStyle(Look.text)
                            if !item.detail.isEmpty { Text(item.detail).font(.subheadline).foregroundStyle(Look.dim) }
                        }
                    }
                    if !target.session.lastReply.isEmpty {
                        Text("Claude's last message").font(.caption.weight(.semibold)).foregroundStyle(Look.dim)
                        Text(target.session.lastReply)
                            .font(.system(size: 14)).foregroundStyle(Look.text.opacity(0.85))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Look.chip, in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("Your reply").font(.caption.weight(.semibold)).foregroundStyle(Look.dim)
                    TextField("Type a reply", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .padding(12)
                        .background(Look.chip, in: RoundedRectangle(cornerRadius: 10))
                    Text(store.macAsleep ? "Your Mac seems asleep: the reply goes through when it wakes."
                                         : "Your Mac types it into the session, or reopens the session with it.")
                        .font(.footnote).foregroundStyle(Look.dim)
                }
                .padding(16)
            }
            .background(Look.bg.ignoresSafeArea())
            .navigationTitle(target.session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await store.send(text, session: target.session, item: target.item) }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
