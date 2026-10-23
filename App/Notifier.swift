import ServiceManagement
import UserNotifications

/// "Waiting on you" alerts and the launch-at-login switch.
enum Notifier {
    private static let notifiedKey = "notifiedItems"
    private static let idleBeforeAlert: TimeInterval = 15 * 60

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Alerts once per task that has waited on the user for 15 minutes while its session sits idle.
    static func check(_ sessions: [TodoSession]) {
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        var changed = false
        for s in sessions where s.live && !s.busy && s.id != TodoStore.manualID && Date().timeIntervalSince(s.updatedAt) >= idleBeforeAlert {
            for item in s.items where item.needsYou && item.status != .completed {
                let key = itemKey(s.id, item.content)
                guard notified.insert(key).inserted else { continue }
                changed = true
                let content = UNMutableNotificationContent()
                content.title = "Waiting on you · \(s.title)"
                content.body = item.detail.isEmpty ? item.content : "\(item.content): \(item.detail)"
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            }
        }
        if changed { UserDefaults.standard.set(Array(notified.suffix(500)), forKey: notifiedKey) }
    }

    // MARK: Login item

    static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
    }

    /// First run: start with the Mac, since a to-do board nobody launches is useless. The footer switch undoes it.
    static func enableLoginOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: "loginItemInit") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemInit")
        setLaunchAtLogin(true)
    }
}
