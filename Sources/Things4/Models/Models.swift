import Foundation

// MARK: - Core model

enum TaskType: String, Codable {
    case todo
    case project
    case heading
    /// A page in Ideas: not committed to yet, promoted to a project when it's time.
    case idea
}

enum TaskStatus: String, Codable {
    case open
    case completed
    case canceled
    case trashed
}

/// Where an open to-do stands. Done and Canceled live in `TaskStatus`.
enum Stage: String, Codable, CaseIterable {
    case backlog
    case todo
    case progress
    case waiting

    var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .todo: return "Todo"
        case .progress: return "In Progress"
        case .waiting: return "Waiting"
        }
    }

    /// Projects reuse the column: a project is planned, active or paused.
    var projectTitle: String {
        switch self {
        case .backlog: return "Planned"
        case .waiting: return "Paused"
        default: return "Active"
        }
    }
}

/// How far an idea has been thought through.
enum IdeaStage: String, Codable, CaseIterable {
    case raw
    case researching
    case ready

    var title: String {
        switch self {
        case .raw: return "Raw"
        case .researching: return "Researching"
        case .ready: return "Ready"
        }
    }

    static func named(_ raw: String) -> IdeaStage? {
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return allCases.first { $0.rawValue == key || (!key.isEmpty && $0.title.lowercased().hasPrefix(key)) }
    }
}

enum Priority: Int, Codable, CaseIterable {
    case none = 0, low, medium, high, urgent

    var title: String {
        switch self {
        case .none: return "No Priority"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    static func named(_ raw: String) -> Priority? {
        if let number = Int(raw) { return Priority(rawValue: number) }
        return allCases.first { $0.title.lowercased().hasPrefix(raw.lowercased()) && !raw.isEmpty } ?? (raw.lowercased() == "none" ? Priority.none : nil)
    }
}

/// Stage plus the two closed states: the six statuses the UI shows.
enum Flow: String, CaseIterable {
    case backlog, todo, progress, waiting, done, canceled

    var title: String {
        switch self {
        case .done: return "Done"
        case .canceled: return "Canceled"
        default: return Stage(rawValue: rawValue)?.title ?? rawValue
        }
    }

    var stage: Stage? { Stage(rawValue: rawValue) }

    /// How lists order groups: what is moving first, what is finished last.
    static let listOrder: [Flow] = [.progress, .waiting, .todo, .backlog, .done, .canceled]
    static let boardOrder: [Flow] = [.backlog, .todo, .progress, .waiting, .done]

    static func named(_ raw: String) -> Flow? {
        switch raw.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "") {
        case "backlog": return .backlog
        case "todo", "next": return .todo
        case "progress", "inprogress", "doing", "started": return .progress
        case "waiting", "blocked": return .waiting
        case "done", "completed", "complete": return .done
        case "canceled", "cancelled": return .canceled
        default: return nil
        }
    }
}

/// Where a to-do lives before it gets a date.
enum StartBucket: String, Codable {
    case inbox
    case anytime
    case someday
    case scheduled
}

struct ChecklistItem: Identifiable, Equatable {
    var id: String
    var title: String
    var done: Bool
    var index: Int
}

/// How a to-do repeats. Stored as JSON in the `repeat_rule` column.
struct RepeatRule: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable {
        case daily, weekly, monthly, yearly

        var title: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }

        var unit: String {
            switch self {
            case .daily: return "day"
            case .weekly: return "week"
            case .monthly: return "month"
            case .yearly: return "year"
            }
        }

        var component: Calendar.Component {
            switch self {
            case .daily: return .day
            case .weekly: return .weekOfYear
            case .monthly: return .month
            case .yearly: return .year
            }
        }
    }

    var frequency: Frequency
    var interval: Int = 1
    /// True: the next occurrence is measured from the completion date.
    /// False: from the scheduled start date.
    var afterCompletion: Bool = false

    var summary: String {
        let base = interval == 1 ? frequency.title : "Every \(interval) \(frequency.unit)s"
        return afterCompletion ? base + " after completion" : base
    }

    func next(after date: Date) -> Date {
        Calendar.current.date(byAdding: frequency.component, value: max(1, interval), to: date) ?? date
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ value: String?) -> RepeatRule? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RepeatRule.self, from: data)
    }
}

/// A stretch of focused time logged against a to-do.
struct TimeEntry: Equatable {
    let id: String
    let taskID: String
    let start: Date
    let end: Date
    let seconds: Int
    let source: String?
    let note: String?
}

enum Duration {
    /// 40m, 1h 20m, 3h.
    static func text(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct TaskItem: Identifiable, Equatable {
    var id: String
    var type: TaskType
    var title: String
    var notes: String
    var status: TaskStatus
    var bucket: StartBucket
    var startDate: Date?
    var deadline: Date?
    var projectID: String?
    var areaID: String?
    var headingID: String?
    var index: Int
    var createdAt: Date
    var modifiedAt: Date
    var completedAt: Date?
    var tags: [String]
    var checklist: [ChecklistItem]
    var isEvening: Bool = false
    var repeatRule: RepeatRule? = nil
    /// Exact moment to post a Mac notification for this to-do.
    var reminder: Date? = nil
    var stage: Stage = .todo
    var priority: Priority = .none
    /// Estimated effort in minutes; 0 means no estimate.
    var estimate: Int = 0
    /// Free text: who or what a Waiting to-do is held up by.
    var waitingOn: String? = nil
    /// The to-do that has to finish first. Completing it moves this one back to Todo.
    var blockedBy: String? = nil
    var ideaStage: IdeaStage = .raw

    var flow: Flow {
        switch status {
        case .completed: return .done
        case .canceled: return .canceled
        default: return Flow(rawValue: stage.rawValue) ?? .todo
        }
    }

    var isOpen: Bool { status == .open }
    var isCompleted: Bool { status == .completed || status == .canceled }
    var isCanceled: Bool { status == .canceled }
    var isProject: Bool { type == .project }
    var isHeading: Bool { type == .heading }
    var isTodo: Bool { type == .todo }
    var isIdea: Bool { type == .idea }

    /// The first line of an idea's notes that reads as prose: its one-line pitch.
    var pitch: String {
        for line in notes.split(separator: "\n") {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") || text.hasPrefix("```") || text.hasPrefix("---") { continue }
            for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "> "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
            return text
        }
        return ""
    }

    var checklistDone: Int { checklist.filter(\.done).count }

    var displayDate: Date? { startDate ?? deadline }

    /// A to-do shows in Today when it starts today or earlier, or its deadline has arrived.
    var isDueToday: Bool {
        let endOfToday = Date().startOfDay.addingDays(1)
        if let start = startDate, start < endOfToday { return true }
        if let deadline, deadline < endOfToday { return true }
        if bucket == .scheduled, startDate == nil { return true }
        return false
    }

    static func newID() -> String { UUID().uuidString }
}

struct Area: Identifiable, Equatable {
    var id: String
    var title: String
    var index: Int
    var createdAt: Date
}

// MARK: - Sidebar selection

enum BuiltinList: String, CaseIterable {
    case inbox
    case today
    case upcoming
    case anytime
    case someday
    case logbook
    case trash
    /// Everything In Progress or Waiting, across every project.
    case active
    /// Projects not committed to yet: notes and research until they're promoted.
    case ideas

    var title: String {
        switch self {
        case .active: return "Active"
        case .ideas: return "Ideas"
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .anytime: return "Anytime"
        case .someday: return "Someday"
        case .logbook: return "Logbook"
        case .trash: return "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .active: return "workflow.active"
        case .ideas: return "lightbulb.fill"
        case .inbox: return "things.inbox"
        case .today: return "things.today"
        case .upcoming: return "things.upcoming"
        case .anytime: return "things.anytime"
        case .someday: return "things.someday"
        case .logbook: return "things.logbook"
        case .trash: return "trash"
        }
    }
}

enum Selection: Equatable {
    case builtin(BuiltinList)
    case project(String)
    case area(String)
    case tag(String)

    var isToday: Bool { self == .builtin(.today) }
}

// MARK: - Dates

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func addingDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    func adding(_ component: Calendar.Component, _ value: Int) -> Date {
        Calendar.current.date(byAdding: component, value: value, to: self) ?? self
    }

    var isToday: Bool { Calendar.current.isDateInToday(self) }
    var isTomorrow: Bool { Calendar.current.isDateInTomorrow(self) }
    var isPast: Bool { startOfDay < Date().startOfDay }

    var daysFromToday: Int {
        Calendar.current.dateComponents([.day], from: Date().startOfDay, to: startOfDay).day ?? 0
    }

    var shortString: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: self)
    }

    var monthDayString: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: self)
    }

    var weekdayString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: self)
    }

    var dayNumberString: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: self)
    }

    static func fromISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: value)
    }

    var isoString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: self)
    }
}
