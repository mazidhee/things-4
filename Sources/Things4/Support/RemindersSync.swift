import AppKit
import EventKit

/// Two-way sync with Apple Reminders, which iCloud carries to iPhone, iPad and
/// Apple Watch. Each open project and area gets a Reminders list, plus "Inbox"
/// and "Anytime" for loose to-dos. A to-do's When date (or deadline) is the
/// reminder's date, so Reminders' Today matches Things' Today; a time adds an alert.
///
/// Each to-do is linked to its reminder by the URL things4://task/<id>. A
/// snapshot of what both sides looked like after the last sync decides who
/// changed what; when both changed the same field, the newer edit wins.
/// Lists you made yourself in Reminders are never read or touched.
final class RemindersSync {
    static let shared = RemindersSync(backend: EventKitReminders.sharedStatus)

    static let urlPrefix = "things4://task/"
    static let didSync = Notification.Name("Things4.remindersDidSync")

    /// What a linked pair looked like after the last sync.
    struct Snapshot: Codable, Equatable {
        var title: String
        var notes: String
        var due: String?        // "2026-11-09", or "2026-11-09T14:30" with an alert
        var completed: Bool
        var list: String        // inbox | anytime | project:<id> | area:<id>
    }

    struct ManagedList: Codable { var id: String; var title: String }

    struct State: Codable {
        var lists: [String: ManagedList] = [:]
        var items: [String: Snapshot] = [:]
    }

    private let backend: RemindersBackend
    private let stateURL: URL
    private(set) var state = State()
    private var scheduled = false
    private var running = false
    private(set) var lastSync: Date?
    private(set) var lastSummary = ""
    /// Writes made by the last pass (tests use it to check a pass was a no-op).
    private(set) var lastWrites = 0

    /// Tests turn sync on without touching your real preference.
    private let alwaysOn: Bool

    init(backend: RemindersBackend, stateURL: URL? = nil, alwaysOn: Bool = false) {
        self.backend = backend
        self.alwaysOn = alwaysOn
        self.stateURL = stateURL ?? APIConfig.directory.appendingPathComponent("reminders-sync.json")
        if let data = try? Data(contentsOf: self.stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    var isActive: Bool { (alwaysOn || Preferences.remindersSync) && backend.hasAccess }

    func start() {
        NotificationCenter.default.addObserver(forName: .storeDidChange, object: nil, queue: .main) { [weak self] _ in self?.scheduleSync() }
        backend.onChange = { [weak self] in self?.scheduleSync() }
        scheduleSync()
    }

    func scheduleSync() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.scheduled = false
            self?.sync()
        }
    }

    func sync(completion: (() -> Void)? = nil) {
        guard isActive, !running else { completion?(); return }
        running = true
        ensureLists()
        let ids = state.lists.values.map(\.id)
        backend.fetch(listIDs: ids) { [weak self] remote in
            guard let self else { return }
            self.reconcile(remote)
            self.running = false
            completion?()
        }
    }

    /// Turning sync off: optionally removes the lists Things made in Reminders.
    func disable(removeLists: Bool) {
        if removeLists && backend.hasAccess {
            state.lists.values.forEach { backend.deleteList($0.id) }
            backend.commit()
        }
        state = State()
        save()
    }

    // MARK: - Lists

    private static let colors: [String: NSColor] = ["inbox": .systemBlue, "anytime": .systemTeal]

    /// The lists there should be, keyed inbox | anytime | project:<id> | area:<id>.
    private func desiredLists() -> [String: String] {
        let store = TaskStore.shared
        var lists = ["inbox": "Inbox", "anytime": "Anytime"]
        for area in store.areas { lists["area:\(area.id)"] = area.title }
        for project in store.tasks where project.isProject && project.isOpen { lists["project:\(project.id)"] = project.title }
        return lists
    }

    private func ensureLists() {
        let existing = backend.lists()
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let desired = desiredLists()
        let managedIDs = Set(state.lists.values.map(\.id))
        let store = TaskStore.shared

        // Migrate the old one-way "Things 4" mirror list into Anytime.
        if state.lists["anytime"] == nil, let old = Preferences.phoneReminderListID, let list = byID[old] {
            state.lists["anytime"] = ManagedList(id: list.id, title: list.title)
            Preferences.phoneReminderListID = nil
        }

        for (key, record) in state.lists {
            guard desired[key] != nil else {
                // Project finished or area removed: its list goes. Its linked to-dos
                // are closed or gone in Things, so forget them rather than trash anything.
                if byID[record.id] != nil { backend.deleteList(record.id) }
                state.lists[key] = nil
                state.items = state.items.filter { $0.value.list != key }
                continue
            }
            guard let live = byID[record.id] else { state.lists[key] = nil; continue }  // deleted on the phone: recreate below
            if live.title != record.title {
                // Renamed on the phone: rename the project or area too.
                if key.hasPrefix("project:") { store.renameProject(String(key.dropFirst(8)), to: live.title) }
                else if key.hasPrefix("area:") { store.renameArea(String(key.dropFirst(5)), to: live.title) }
                state.lists[key]?.title = live.title
            }
        }

        let desiredNow = desiredLists()
        for (key, title) in desiredNow {
            if var record = state.lists[key] {
                if record.title != title {
                    backend.renameList(record.id, to: title)
                    record.title = title
                    state.lists[key] = record
                }
                continue
            }
            // Never adopt a list the user made: pick a free name instead.
            let taken = Set(existing.filter { !managedIDs.contains($0.id) }.map { $0.title.lowercased() })
            let name = taken.contains(title.lowercased()) ? "\(title) (Things)" : title
            let color = Self.colors[key] ?? (key.hasPrefix("area:") ? .systemGreen : .systemIndigo)
            if let id = backend.createList(title: name, color: color) {
                state.lists[key] = ManagedList(id: id, title: name)
            }
        }
        backend.commit()
    }

    private func listKey(forListID id: String) -> String? {
        state.lists.first { $0.value.id == id }?.key
    }

    // MARK: - Values

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
    private static let dayFormat = formatter("yyyy-MM-dd")
    private static let timeFormat = formatter("yyyy-MM-dd'T'HH:mm")

    static func dueString(_ task: TaskItem) -> String? {
        if task.bucket == .scheduled, let reminder = task.reminder { return timeFormat.string(from: reminder) }
        if task.bucket == .scheduled { return dayFormat.string(from: task.startDate ?? Date().startOfDay) }
        if let deadline = task.deadline { return dayFormat.string(from: deadline) }
        return nil
    }

    static func listKey(for task: TaskItem) -> String {
        let store = TaskStore.shared
        if let projectID = task.projectID { return "project:\(projectID)" }
        if let areaID = task.areaID, store.area(areaID) != nil { return "area:\(areaID)" }
        if task.bucket == .inbox && task.startDate == nil { return "inbox" }
        return "anytime"
    }

    static func snapshot(of task: TaskItem) -> Snapshot {
        Snapshot(title: task.title, notes: task.notes, due: dueString(task), completed: task.isCompleted, list: listKey(for: task))
    }

    private func snapshot(of reminder: RemoteReminder) -> Snapshot? {
        guard let list = listKey(forListID: reminder.listID) else { return nil }
        return Snapshot(title: reminder.title, notes: reminder.notes, due: reminder.due, completed: reminder.completed, list: list)
    }

    static func taskID(from url: String?) -> String? {
        guard let url, url.hasPrefix(urlPrefix) else { return nil }
        return String(url.dropFirst(urlPrefix.count))
    }

    // MARK: - Reconcile

    private func reconcile(_ remote: [RemoteReminder]) {
        let store = TaskStore.shared
        let managed = Set(state.lists.keys)
        var writes = 0
        var created = 0, pulled = 0

        var linked: [String: RemoteReminder] = [:]
        var fresh: [RemoteReminder] = []
        for reminder in remote {
            if let id = Self.taskID(from: reminder.url) {
                if linked[id] == nil { linked[id] = reminder } else { backend.delete(reminder.id); writes += 1 }  // duplicate
            } else if !reminder.completed {
                fresh.append(reminder)
            }
        }

        // To-dos that belong in Reminders: open ones, plus closed ones still linked.
        let syncable = store.tasks.filter { task in
            guard task.isTodo, task.status != .trashed, managed.contains(Self.listKey(for: task)) else { return false }
            return task.isOpen || state.items[task.id] != nil
        }
        let syncableIDs = Set(syncable.map(\.id))

        // Many reminders vanishing at once looks like a glitch, not a decision:
        // put them back instead of trashing to-dos.
        let vanished = syncable.filter { state.items[$0.id] != nil && linked[$0.id] == nil }
        let trustDeletions = vanished.count <= 5 || Double(vanished.count) <= Double(state.items.count) * 0.3
        if !trustDeletions { NSLog("Things 4 sync: \(vanished.count) reminders missing at once, restoring them instead of deleting to-dos") }

        store.batch("Sync with Reminders") {
            for task in syncable {
                let things = Self.snapshot(of: task)
                guard let reminder = linked[task.id] else {
                    // A finished to-do's reminder going away is just "Clear Completed": keep the to-do.
                    if state.items[task.id] != nil, !task.isOpen { state.items[task.id] = nil; continue }
                    if state.items[task.id] != nil, trustDeletions {
                        store.moveToTrash(task.id)  // deleted on the phone
                        state.items[task.id] = nil
                        pulled += 1
                        continue
                    }
                    guard task.isOpen else { state.items[task.id] = nil; continue }
                    if push(things, into: RemoteReminder(id: "", listID: "", title: "", notes: "", due: nil, completed: false, url: Self.urlPrefix + task.id, modified: Date())) {
                        state.items[task.id] = things
                        writes += 1
                        created += 1
                    }
                    continue
                }
                guard let phone = snapshot(of: reminder) else { continue }
                guard let base = state.items[task.id] else {
                    // First link (or migrated mirror item): Things wins.
                    if phone != things { _ = push(things, into: reminder); writes += 1 }
                    state.items[task.id] = things
                    continue
                }
                var merged = base
                var toPhone = false
                var fromPhone = false
                let phoneNewer = reminder.modified > task.modifiedAt
                func pick<T: Equatable>(_ key: WritableKeyPath<Snapshot, T>) {
                    let t = things[keyPath: key], p = phone[keyPath: key], b = base[keyPath: key]
                    if t == p { merged[keyPath: key] = t; return }
                    if p == b || (t != b && !phoneNewer) { merged[keyPath: key] = t; toPhone = true }
                    else { merged[keyPath: key] = p; fromPhone = true }
                }
                pick(\.list); pick(\.due); pick(\.completed); pick(\.title); pick(\.notes)
                if fromPhone { apply(merged, from: things, to: task); pulled += 1 }
                if toPhone { _ = push(merged, into: reminder); writes += 1 }
                state.items[task.id] = merged
            }

            // Linked reminders whose to-do is gone, trashed or moved out of sync.
            for (id, reminder) in linked where !syncableIDs.contains(id) {
                backend.delete(reminder.id)
                state.items[id] = nil
                writes += 1
            }
            for id in state.items.keys where !syncableIDs.contains(id) && linked[id] == nil { state.items[id] = nil }

            // New on the phone: make the to-do and link it.
            for reminder in fresh {
                guard let key = listKey(forListID: reminder.listID) else { continue }
                let container = Self.container(for: key)
                let task = store.createTask(title: reminder.title, notes: reminder.notes,
                                            bucket: key == "inbox" ? .inbox : .anytime,
                                            projectID: container.projectID, areaID: container.areaID)
                if let due = reminder.due { applyDue(due, to: task.id) }
                guard let made = store.task(task.id) else { continue }
                var linkedReminder = reminder
                linkedReminder.url = Self.urlPrefix + made.id
                _ = push(Self.snapshot(of: made), into: linkedReminder)
                state.items[made.id] = Self.snapshot(of: made)
                writes += 1
                pulled += 1
            }
        }

        // Prune long-finished pairs so the state file stays small.
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        for (id, snap) in state.items where snap.completed {
            if let task = store.task(id), (task.completedAt ?? .distantPast) < cutoff { state.items[id] = nil }
        }

        backend.commit()
        save()
        lastWrites = writes
        lastSync = Date()
        let lists = state.lists.count
        lastSummary = "\(state.items.count) to-dos in \(lists) lists" + (created + pulled > 0 ? " · \(created) sent, \(pulled) received" : "")
        NotificationCenter.default.post(name: Self.didSync, object: nil)
    }

    static func container(for key: String) -> (projectID: String?, areaID: String?) {
        if key.hasPrefix("project:") {
            let id = String(key.dropFirst(8))
            return (id, TaskStore.shared.task(id)?.areaID)
        }
        if key.hasPrefix("area:") { return (nil, String(key.dropFirst(5))) }
        return (nil, nil)
    }

    /// Writes a snapshot into a reminder; an empty id creates it.
    @discardableResult
    private func push(_ snap: Snapshot, into reminder: RemoteReminder) -> Bool {
        guard let list = state.lists[snap.list] else { return false }
        var updated = reminder
        updated.listID = list.id
        updated.title = snap.title
        updated.notes = snap.notes
        updated.due = snap.due
        updated.completed = snap.completed
        return backend.save(updated) != nil
    }

    /// Applies what changed on the phone to the to-do.
    private func apply(_ merged: Snapshot, from things: Snapshot, to task: TaskItem) {
        let store = TaskStore.shared
        let id = task.id
        if merged.list != things.list {
            let container = Self.container(for: merged.list)
            store.move(id, toProject: container.projectID, areaID: container.areaID)
            if merged.list == "inbox" { store.setBucket(id, bucket: .inbox) }
        }
        if merged.due != things.due {
            if let due = merged.due { applyDue(due, to: id) }
            else if let current = store.task(id) {
                if current.bucket == .scheduled { store.setBucket(id, bucket: .anytime) }
                else if current.deadline != nil { store.setDeadline(id, date: nil) }
            }
        }
        if merged.completed != things.completed, let current = store.task(id) {
            if merged.completed && current.isOpen { store.toggleCompletion(id) }
            if !merged.completed && current.isCompleted { store.reopen(id) }
        }
        if merged.title != things.title, !merged.title.isEmpty { store.setTitle(id, merged.title) }
        if merged.notes != things.notes { store.setNotes(id, merged.notes) }
    }

    private func applyDue(_ due: String, to id: String) {
        let store = TaskStore.shared
        guard let task = store.task(id) else { return }
        if let at = Self.timeFormat.date(from: due) {
            store.setReminder(id, at: at)
        } else if let day = Self.dayFormat.date(from: due) {
            let deadlineOnly = task.bucket != .scheduled && task.deadline != nil
            if deadlineOnly { store.setDeadline(id, date: day); return }
            if task.reminder != nil { store.setReminder(id, at: nil) }
            store.setBucket(id, bucket: .scheduled, date: day)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

// MARK: - Backend

struct RemoteList { var id: String; var title: String }

struct RemoteReminder {
    var id: String          // empty: not created yet
    var listID: String
    var title: String
    var notes: String
    var due: String?
    var completed: Bool
    var url: String?
    var modified: Date
}

/// What the sync needs from Reminders. EventKitReminders is the real one; the
/// self-test uses an in-memory fake so it never touches your iCloud.
protocol RemindersBackend: AnyObject {
    var hasAccess: Bool { get }
    var onChange: (() -> Void)? { get set }
    func lists() -> [RemoteList]
    func fetch(listIDs: [String], completion: @escaping ([RemoteReminder]) -> Void)
    func createList(title: String, color: NSColor) -> String?
    func renameList(_ id: String, to title: String)
    func deleteList(_ id: String)
    func save(_ reminder: RemoteReminder) -> String?
    func delete(_ id: String)
    func commit()
}

final class EventKitReminders: RemindersBackend {
    static let sharedStatus = EventKitReminders()
    let store = EKEventStore()
    var onChange: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.onChange?()
        }
    }

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    var hasAccess: Bool { status == .fullAccess }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToReminders { granted, _ in DispatchQueue.main.async { completion(granted) } }
    }

    func lists() -> [RemoteList] {
        store.calendars(for: .reminder).map { RemoteList(id: $0.calendarIdentifier, title: $0.title) }
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    func fetch(listIDs: [String], completion: @escaping ([RemoteReminder]) -> Void) {
        let calendars = listIDs.compactMap { store.calendar(withIdentifier: $0) }
        guard !calendars.isEmpty else { completion([]); return }
        store.fetchReminders(matching: store.predicateForReminders(in: calendars)) { reminders in
            let items = (reminders ?? []).map { reminder -> RemoteReminder in
                var due: String?
                if let parts = reminder.dueDateComponents, let date = Calendar.current.date(from: parts) {
                    due = parts.hour != nil ? Self.timeFormat.string(from: date) : Self.dayFormat.string(from: date)
                }
                return RemoteReminder(id: reminder.calendarItemIdentifier, listID: reminder.calendar.calendarIdentifier,
                                      title: reminder.title ?? "", notes: reminder.notes ?? "", due: due,
                                      completed: reminder.isCompleted, url: reminder.url?.absoluteString,
                                      modified: reminder.lastModifiedDate ?? .distantPast)
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    private func source() -> EKSource? {
        store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .calDAV && $0.title == "iCloud" }
            ?? store.sources.first { $0.sourceType == .local }
    }

    func createList(title: String, color: NSColor) -> String? {
        guard let source = source() else { return nil }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title
        list.cgColor = color.cgColor
        list.source = source
        do {
            try store.saveCalendar(list, commit: false)
            return list.calendarIdentifier
        } catch {
            NSLog("Things 4 sync: couldn't create list \(title): \(error.localizedDescription)")
            return nil
        }
    }

    func renameList(_ id: String, to title: String) {
        guard let list = store.calendar(withIdentifier: id) else { return }
        list.title = title
        try? store.saveCalendar(list, commit: false)
    }

    func deleteList(_ id: String) {
        guard let list = store.calendar(withIdentifier: id) else { return }
        try? store.removeCalendar(list, commit: false)
    }

    func save(_ item: RemoteReminder) -> String? {
        let reminder = item.id.isEmpty ? EKReminder(eventStore: store) : (store.calendarItem(withIdentifier: item.id) as? EKReminder ?? EKReminder(eventStore: store))
        guard let list = store.calendar(withIdentifier: item.listID) else { return nil }
        reminder.calendar = list
        reminder.title = item.title
        reminder.notes = item.notes.isEmpty ? nil : item.notes
        reminder.url = item.url.flatMap(URL.init(string:))
        reminder.alarms?.forEach(reminder.removeAlarm)
        if let due = item.due, let date = Self.timeFormat.date(from: due) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            if date > Date() { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        } else if let due = item.due, let date = Self.dayFormat.date(from: due) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: date)
        } else {
            reminder.dueDateComponents = nil
        }
        if reminder.isCompleted != item.completed { reminder.isCompleted = item.completed }
        do {
            try store.save(reminder, commit: false)
            return reminder.calendarItemIdentifier
        } catch {
            NSLog("Things 4 sync: couldn't save \(item.title): \(error.localizedDescription)")
            return nil
        }
    }

    func delete(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? store.remove(reminder, commit: false)
    }

    func commit() {
        try? store.commit()
    }
}
