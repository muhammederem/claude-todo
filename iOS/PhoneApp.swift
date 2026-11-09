import CloudKit
import SwiftUI
import UserNotifications

@main
struct ClaudeTodoPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneDelegate.self) private var delegate
    @StateObject private var store = PhoneStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneView(store: store)
                .onOpenURL { store.open($0) }
                .task { await store.refresh() }
                .onChange(of: phase) { _, now in if now == .active { Task { await store.refresh() } } }
        }
    }
}

/// Push registration and the "waiting on you" notification with Approve / Edit actions.
final class PhoneDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let replyCategory = "REPLY"
    private static let approve = "APPROVE"
    private static let edit = "EDIT"
    private static let typed = "TYPED"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.replyCategory,
            actions: [
                // it sends text to a session on the Mac, so it asks for Face ID on a locked phone
                UNNotificationAction(identifier: Self.approve, title: "Approve suggestion", options: [.authenticationRequired]),
                UNTextInputNotificationAction(identifier: Self.typed, title: "Reply…", options: [.authenticationRequired],
                                              textInputButtonTitle: "Send", textInputPlaceholder: "Your reply to Claude"),
                UNNotificationAction(identifier: Self.edit, title: "Edit suggestion…", options: [.foreground]),
            ],
            intentIdentifiers: [])])
        guard !PhoneStore.demo else { return true }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        Task { await PhoneStore.shared.subscribe() }
        return true
    }

    /// Silent push: the Mac changed the board.
    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        await PhoneStore.shared.refresh()
        return .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let note = CKNotification(fromRemoteNotificationDictionary: response.notification.request.content.userInfo)
                as? CKQueryNotification,
              let fields = note.recordFields,
              let sessionID = fields["sessionID"] as? String else { return }
        let title = fields["itemTitle"] as? String ?? ""
        let suggestion = fields["suggestion"] as? String ?? ""
        if let typed = (response as? UNTextInputNotificationResponse)?.userText {
            // typed straight into the notification: send it as is, the app never opens
            await PhoneStore.shared.handle(sessionID: sessionID, itemTitle: title, suggestion: typed, edit: false)
            return
        }
        let edit = response.actionIdentifier != Self.approve
        await PhoneStore.shared.handle(sessionID: sessionID, itemTitle: title, suggestion: suggestion, edit: edit)
    }
}
