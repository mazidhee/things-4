import Foundation

// MARK: - Core model

enum TaskType: String, Codable {
    case todo
    case project
    case heading
}

enum TaskStatus: String, Codable {
    case open
    case completed
    case canceled
    case trashed
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

    var isOpen: Bool { status == .open }
    var isCompleted: Bool { status == .completed || status == .canceled }
    var isCanceled: Bool { status == .canceled }
    var isProject: Bool { type == .project }
    var isHeading: Bool { type == .heading }
    var isTodo: Bool { type == .todo }

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

    var title: String {
        switch self {
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
