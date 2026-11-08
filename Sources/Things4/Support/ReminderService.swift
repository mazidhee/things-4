import AppKit
import UserNotifications

/// Posts a Mac notification at each to-do's reminder time. Notifications are
/// rebuilt from the store whenever it changes, so edits, completions and
/// deletions always cancel or move the right notification.
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderService()

    private static let category = "THINGS4_REMINDER"
    private static let prefix = "todo-"
    private var center: UNUserNotificationCenter? {
        // UserNotifications needs a real app bundle; the headless self-test has none.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    private var syncScheduled = false
    private(set) var authorized = false

    func start() {
        guard let center else { return }
        center.delegate = self
        let complete = UNNotificationAction(identifier: "complete", title: "Complete", options: [])
        let snooze15 = UNNotificationAction(identifier: "snooze15", title: "Snooze 15 Minutes", options: [])
        let snooze60 = UNNotificationAction(identifier: "snooze60", title: "Snooze 1 Hour", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [complete, snooze15, snooze60],
                                                                 intentIdentifiers: [], options: [])])
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .storeDidChange, object: nil)
        center.getNotificationSettings { settings in
            self.authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined, TaskStore.shared.tasks.contains(where: { $0.reminder != nil }) {
                self.requestAuthorization()
            }
            DispatchQueue.main.async { self.sync() }
        }
    }

    /// Asked the first time a reminder is set, like Things.
    func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("Things 4 notification authorization error: \(error.localizedDescription)") }
            if CommandLine.arguments.contains("--reminder-check") {
                print("requestAuthorization granted=\(granted) error=\(String(describing: error))"); fflush(stdout)
            }
            self.authorized = granted
            DispatchQueue.main.async {
                self.sync()
                completion?(granted)
            }
        }
    }

    @objc private func storeChanged() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.sync()
        }
    }

    private func identifier(for task: TaskItem, at date: Date) -> String {
        "\(Self.prefix)\(task.id)-\(Int(date.timeIntervalSince1970))"
    }

    /// Makes the pending notifications match the store exactly.
    func sync() {
        guard let center else { return }
        let now = Date()
        var wanted: [String: (TaskItem, Date)] = [:]
        for task in TaskStore.shared.tasks where task.isTodo && task.isOpen {
            guard let reminder = task.reminder, reminder > now else { continue }
            wanted[identifier(for: task, at: reminder)] = (task, reminder)
        }
        if !wanted.isEmpty && !authorized {
            center.getNotificationSettings { settings in
                if settings.authorizationStatus == .notDetermined { self.requestAuthorization() }
            }
        }
        center.getPendingNotificationRequests { pending in
            let existing = Set(pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) })
            let stale = existing.subtracting(wanted.keys)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
            for (id, (task, date)) in wanted where !existing.contains(id) {
                let content = UNMutableNotificationContent()
                content.title = task.title
                let parent = task.projectID.flatMap { TaskStore.shared.task($0)?.title } ?? task.areaID.flatMap { TaskStore.shared.area($0)?.title }
                content.body = parent ?? (Markdown.plainPreview(task.notes, limit: 120).isEmpty ? "Reminder" : Markdown.plainPreview(task.notes, limit: 120))
                content.sound = .default
                content.categoryIdentifier = Self.category
                content.userInfo = ["taskID": task.id]
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }

    // MARK: - Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let taskID = response.notification.request.content.userInfo["taskID"] as? String
        DispatchQueue.main.async {
            defer { completionHandler() }
            guard let taskID, let task = TaskStore.shared.task(taskID) else { return }
            switch response.actionIdentifier {
            case "complete":
                if task.isOpen { TaskStore.shared.toggleCompletion(taskID) }
            case "snooze15":
                TaskStore.shared.setReminder(taskID, at: Date().addingTimeInterval(15 * 60))
            case "snooze60":
                TaskStore.shared.setReminder(taskID, at: Date().addingTimeInterval(60 * 60))
            default:
                MainWindowController.shared.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openTask, object: taskID)
            }
        }
    }
}
