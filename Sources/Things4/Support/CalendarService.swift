import AppKit
import EventKit

extension Notification.Name {
    static let calendarDidChange = Notification.Name("Things4.calendarDidChange")
}

/// Calendar events for Today and Upcoming. Reads every account configured on the
/// Mac (iCloud, Google, Exchange / Outlook, CalDAV) through EventKit, read-only.
final class CalendarService {
    static let shared = CalendarService()

    struct Event {
        let id: String
        let itemID: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: NSColor
        let calendarTitle: String
    }

    let store = EKEventStore()
    private var cache: [Date: [Event]] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.store.refreshSourcesIfNecessary()
            self?.invalidate()
        }
    }

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    var hasAccess: Bool {
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    /// Active when the user turned the feature on and macOS granted access.
    var isActive: Bool { Preferences.calendarsEnabled && hasAccess }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        let done: (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async {
                self.invalidate()
                completion(granted)
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    /// Asks once at launch when calendars are on but macOS has not decided yet.
    func requestIfNeeded() {
        guard Preferences.calendarsEnabled, status == .notDetermined else { return }
        requestAccess { _ in }
    }

    /// Opens the event in Calendar.
    func show(_ event: Event) {
        let encoded = event.itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.itemID
        if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    func invalidate() {
        cache.removeAll()
        NotificationCenter.default.post(name: .calendarDidChange, object: nil)
    }

    /// Calendars grouped by account, for Settings.
    func calendarsBySource() -> [(source: String, calendars: [EKCalendar])] {
        guard hasAccess else { return [] }
        let grouped = Dictionary(grouping: store.calendars(for: .event)) { $0.source?.title ?? "Other" }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.title < $1.title }) }
    }

    private var visibleCalendars: [EKCalendar] {
        let hidden = Preferences.hiddenCalendarIDs
        return store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
    }

    /// Events on a given day, all-day first, then by start time.
    func events(on day: Date) -> [Event] {
        guard isActive else { return [] }
        let start = day.startOfDay
        if let cached = cache[start] { return cached }
        let calendars = visibleCalendars
        guard !calendars.isEmpty else { cache[start] = []; return [] }
        let predicate = store.predicateForEvents(withStart: start, end: start.addingDays(1), calendars: calendars)
        let events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, itemID: $0.calendarItemIdentifier, title: $0.title ?? "Untitled", start: $0.startDate,
                         end: $0.endDate, isAllDay: $0.isAllDay,
                         color: NSColor(cgColor: $0.calendar.cgColor) ?? Theme.accent,
                         calendarTitle: $0.calendar.title) }
            .sorted { first, second in
                if first.isAllDay != second.isAllDay { return first.isAllDay }
                return first.start < second.start
            }
        cache[start] = events
        return events
    }
}

/// Calendar events as Things 3 draws them.
/// Today: one rounded grey card, grey time + title per line.
/// Upcoming: bare lines under the day, time in the calendar's colour;
/// all-day events get a thin coloured bar instead of a time.
final class CalendarEventsView: FlippedView, NSViewToolTipOwner {
    enum Style { case card, list }
    private let events: [CalendarService.Event]
    private let style: Style
    /// Things lets events hang 6pt left of the to-do column.
    var extendsLeft: CGFloat = 0
    static let lineHeight: CGFloat = 16

    init(events: [CalendarService.Event], style: Style) {
        self.events = events
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var rowTop: CGFloat { style == .card ? 9 : 6 }

    private func event(at point: NSPoint) -> CalendarService.Event? {
        let index = Int(floor((point.y - rowTop) / Self.lineHeight))
        return events.indices.contains(index) ? events[index] : nil
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        for index in events.indices {
            addToolTip(NSRect(x: 0, y: rowTop + CGFloat(index) * Self.lineHeight, width: bounds.width, height: Self.lineHeight), owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let event = event(at: point) else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let when = event.isAllDay ? "All day" : "\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))"
        return "\(event.title)\n\(when) · \(event.calendarTitle)\nClick to open in Calendar"
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if let hit = self.event(at: convert(event.locationInWindow, from: nil)) { CalendarService.shared.show(hit) }
    }

    static func height(for events: [CalendarService.Event], style: Style) -> CGFloat {
        guard !events.isEmpty else { return 0 }
        return CGFloat(events.count) * lineHeight + (style == .card ? 18 : 0)
    }

    private static let cardFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.235, green: 0.235, blue: 0.243, alpha: 1)
            : NSColor(srgbRed: 0.937, green: 0.937, blue: 0.945, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        var y: CGFloat = 6
        if style == .card {
            Self.cardFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            x = 10
            y = 9
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: Fonts.regular(13), .foregroundColor: Theme.text]
        for event in events {
            var textX = x
            if event.isAllDay {
                event.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 1, y: y + 3, width: 2.5, height: 11), xRadius: 1, yRadius: 1).fill()
                textX += 9
            } else {
                let time = formatter.string(from: event.start) as NSString
                let timeAttrs: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12.5),
                                                                .foregroundColor: style == .card ? Theme.secondary : event.color]
                time.draw(at: NSPoint(x: textX, y: y), withAttributes: timeAttrs)
                textX += ceil(time.size(withAttributes: timeAttrs).width) + 4
            }
            (event.title as NSString).draw(with: NSRect(x: textX, y: y, width: bounds.width - textX - x, height: Self.lineHeight),
                                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)
            y += Self.lineHeight
        }
    }
}
