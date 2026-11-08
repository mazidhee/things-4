import AppKit
import EventKit

/// Mirrors to-do reminders into a "Things 4" list in Apple Reminders. iCloud
/// syncs that list to iPhone and Apple Watch, which then alert at the same time.
/// Ticking the reminder off on the phone completes the to-do here.
final class PhoneReminders {
    static let shared = PhoneReminders()

    private let store = EKEventStore()
    private static let listName = "Things 4"
    private static let urlPrefix = "things4://task/"
    private var syncScheduled = false

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    var hasAccess: Bool { status == .fullAccess }
    var isActive: Bool { Preferences.phoneReminders && hasAccess }

    func start() {
        NotificationCenter.default.addObserver(forName: .storeDidChange, object: nil, queue: .main) { [weak self] _ in self?.scheduleSync() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.scheduleSync() }
        if Preferences.phoneReminders && status == .notDetermined { requestAccess { _ in } }
        scheduleSync()
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async {
                if granted { self.scheduleSync() }
                completion(granted)
            }
        }
    }

    /// Turning it off removes the mirrored reminders so the phone stops alerting.
    func disable() {
        guard hasAccess, let list = existingList() else { return }
        store.fetchReminders(matching: store.predicateForReminders(in: [list])) { reminders in
            DispatchQueue.main.async {
                for reminder in reminders ?? [] where reminder.url?.absoluteString.hasPrefix(Self.urlPrefix) == true {
                    try? self.store.remove(reminder, commit: false)
                }
                try? self.store.commit()
            }
        }
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.syncScheduled = false
            self?.sync()
        }
    }

    private func existingList() -> EKCalendar? {
        if let id = Preferences.phoneReminderListID, let list = store.calendar(withIdentifier: id) { return list }
        return store.calendars(for: .reminder).first { $0.title == Self.listName }
    }

    /// The "Things 4" list, created in the default (normally iCloud) account.
    private func list() -> EKCalendar? {
        if let list = existingList() {
            Preferences.phoneReminderListID = list.calendarIdentifier
            return list
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listName
        list.cgColor = NSColor.systemBlue.cgColor
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
                ?? store.sources.first(where: { $0.sourceType == .local }) else { return nil }
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
            Preferences.phoneReminderListID = list.calendarIdentifier
            return list
        } catch {
            NSLog("Things 4: could not create the Reminders list: \(error.localizedDescription)")
            return nil
        }
    }

    func sync() {
        guard isActive, let list = list() else { return }
        store.fetchReminders(matching: store.predicateForReminders(in: [list])) { reminders in
            DispatchQueue.main.async { self.reconcile(reminders ?? [], in: list) }
        }
    }

    private func reconcile(_ reminders: [EKReminder], in list: EKCalendar) {
        let tasks = TaskStore.shared
        var mirrored: [String: EKReminder] = [:]
        for reminder in reminders {
            guard let link = reminder.url?.absoluteString, link.hasPrefix(Self.urlPrefix) else { continue }
            mirrored[String(link.dropFirst(Self.urlPrefix.count))] = reminder
        }

        // Ticked off on the phone: complete the to-do.
        for (id, reminder) in mirrored where reminder.isCompleted {
            if let task = tasks.task(id), task.isOpen, task.reminder != nil { tasks.toggleCompletion(id) }
        }

        let today = Date().startOfDay
        var wanted: [String: (TaskItem, Date)] = [:]
        for task in tasks.tasks where task.isTodo && task.isOpen {
            if let at = task.reminder, at >= today { wanted[task.id] = (task, at) }
        }

        var changed = false
        for (id, (task, at)) in wanted {
            let reminder = mirrored[id] ?? EKReminder(eventStore: store)
            if reminder.isCompleted, mirrored[id] != nil { continue }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            let parent = task.projectID.flatMap { tasks.task($0)?.title } ?? task.areaID.flatMap { tasks.area($0)?.title }
            let alarmDate = reminder.alarms?.first?.absoluteDate
            guard mirrored[id] == nil || reminder.title != task.title || alarmDate != at || reminder.notes != parent else { continue }
            reminder.calendar = list
            reminder.title = task.title
            reminder.notes = parent
            reminder.url = URL(string: Self.urlPrefix + id)
            reminder.dueDateComponents = parts
            reminder.alarms?.forEach(reminder.removeAlarm)
            reminder.addAlarm(EKAlarm(absoluteDate: at))
            try? store.save(reminder, commit: false)
            changed = true
        }
        for (id, reminder) in mirrored where wanted[id] == nil {
            try? store.remove(reminder, commit: false)
            changed = true
        }
        if changed { try? store.commit() }
    }
}
