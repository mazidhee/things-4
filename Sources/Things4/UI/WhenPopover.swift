import AppKit

/// Things' When / Deadline picker: a natural-language field, quick picks and a calendar grid.
final class WhenPicker: NSViewController, NSTextFieldDelegate {
    enum Mode { case when, deadline }
    enum Choice { case today, evening, date(Date), someday, anytime, clear, reminder(Date), removeReminder }

    private let mode: Mode
    private let current: Date?
    private let currentReminder: Date?
    private var pickingTime = false
    private let onPick: (Choice) -> Void
    private var monthStart: Date
    private let field = NSTextField()
    private let grid = FlippedView()
    private let monthLabel = NSTextField.label("", font: Fonts.semibold(11.5), color: Theme.secondary)
    private var popover: NSPopover?

    init(mode: Mode, current: Date?, reminder: Date? = nil, onPick: @escaping (Choice) -> Void) {
        self.mode = mode
        self.current = current
        self.currentReminder = reminder
        self.onPick = onPick
        // The grid starts on the Monday of the current week, like Things.
        var start = Date().startOfDay
        while Calendar.current.component(.weekday, from: start) != 2 { start = start.addingDays(-1) }
        self.monthStart = start
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func show(mode: Mode, current: Date?, reminder: Date? = nil, relativeTo rect: NSRect, of view: NSView,
                     onPick: @escaping (Choice) -> Void) {
        let picker = WhenPicker(mode: mode, current: current, reminder: reminder, onPick: onPick)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        picker.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        picker.view.window?.makeFirstResponder(picker.field)
    }

    private var rows: [(String, String, NSColor, Choice)] {
        switch mode {
        case .when:
            return [("Today", "star.fill", Theme.listColor(.today), .today),
                    ("This Evening", "moon.fill", Theme.evening, .evening)]
        case .deadline:
            return []
        }
    }

    private var footerRows: [(String, String, NSColor, Choice)] {
        switch mode {
        case .when:
            var items: [(String, String, NSColor, Choice)] = [("Someday", "archivebox.fill", Theme.listColor(.someday), .someday)]
            if current != nil { items.append(("Clear", "xmark.circle", Theme.secondary, .anytime)) }
            if let currentReminder {
                let f = DateFormatter(); f.timeStyle = .short
                items.append(("Remove Reminder (\(f.string(from: currentReminder)))", "bell.slash", Theme.secondary, .removeReminder))
            }
            return items
        case .deadline:
            return current != nil ? [("Remove Deadline", "xmark.circle", Theme.secondary, .clear)] : []
        }
    }

    override func loadView() {
        let width: CGFloat = 250
        let root = FlippedView()
        var y: CGFloat = 12

        field.placeholderString = mode == .when ? "When" : "Deadline"
        field.font = Fonts.regular(13)
        field.alignment = .center
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.frame = NSRect(x: 12, y: y, width: width - 24, height: 20)
        root.addSubview(field)
        y += 30

        for row in rows {
            root.addSubview(choiceButton(row, frame: NSRect(x: 8, y: y, width: width - 16, height: 26)))
            y += 28
        }
        y += 4

        let headerY = y
        let prev = IconButton(symbol: "chevron.left", size: 10, color: Theme.secondary, tooltip: "Earlier")
        prev.target = self
        prev.action = #selector(previousPage)
        prev.frame = NSRect(x: 12, y: headerY, width: 18, height: 18)
        let next = IconButton(symbol: "chevron.right", size: 10, color: Theme.secondary, tooltip: "Later")
        next.target = self
        next.action = #selector(nextPage)
        next.frame = NSRect(x: width - 30, y: headerY, width: 18, height: 18)
        monthLabel.alignment = .center
        monthLabel.frame = NSRect(x: 36, y: headerY + 1, width: width - 72, height: 16)
        root.addSubview(prev)
        root.addSubview(next)
        root.addSubview(monthLabel)
        y += 22

        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let cell = (width - 24) / 7
        for (i, name) in names.enumerated() {
            let label = NSTextField.label(name, font: Fonts.medium(10.5), color: Theme.tertiary)
            label.alignment = .center
            label.frame = NSRect(x: 12 + CGFloat(i) * cell, y: y, width: cell, height: 14)
            root.addSubview(label)
        }
        y += 18
        grid.frame = NSRect(x: 12, y: y, width: width - 24, height: 6 * 28)
        root.addSubview(grid)
        y += 6 * 28 + 6

        for row in footerRows {
            root.addSubview(choiceButton(row, frame: NSRect(x: 8, y: y, width: width - 16, height: 26)))
            y += 28
        }
        if mode == .when {
            let add = PickerRowButton(title: currentReminder == nil ? "Add Reminder" : "Change Reminder", symbol: "plus",
                                      color: Theme.secondary) { [weak self] in self?.beginTimeEntry() }
            add.frame = NSRect(x: 8, y: y, width: width - 16, height: 26)
            root.addSubview(add)
            y += 28
        }
        y += 8
        root.frame = NSRect(x: 0, y: 0, width: width, height: y)
        preferredContentSize = root.frame.size
        view = root
        buildGrid()
    }

    private func choiceButton(_ row: (String, String, NSColor, Choice), frame: NSRect) -> NSButton {
        let button = PickerRowButton(title: row.0, symbol: row.1, color: row.2) { [weak self] in self?.finish(row.3) }
        button.frame = frame
        return button
    }

    private func buildGrid() {
        grid.removeAllSubviews()
        let cell = grid.bounds.width / 7
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        monthLabel.stringValue = formatter.string(from: monthStart.addingDays(10))
        for index in 0..<42 {
            let date = monthStart.addingDays(index)
            let isPast = date < Date().startOfDay
            let selected = current.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
            let day = Calendar.current.component(.day, from: date)
            let isFirst = day == 1
            let title = date.isToday ? "★" : (isFirst ? date.monthDayString.prefix(3).description : "\(day)")
            let button = DayButton(title: title, isToday: date.isToday, isPast: isPast, isSelected: selected) { [weak self] in
                self?.finish(date.isToday && self?.mode == .when ? .today : .date(date))
            }
            button.frame = NSRect(x: CGFloat(index % 7) * cell, y: CGFloat(index / 7) * 28, width: cell, height: 26)
            button.isEnabled = !isPast
            grid.addSubview(button)
        }
    }

    @objc private func previousPage() {
        let earliest: Date = {
            var start = Date().startOfDay
            while Calendar.current.component(.weekday, from: start) != 2 { start = start.addingDays(-1) }
            return start
        }()
        monthStart = max(earliest, monthStart.addingDays(-42))
        buildGrid()
    }

    @objc private func nextPage() {
        monthStart = monthStart.addingDays(42)
        buildGrid()
    }

    private func beginTimeEntry() {
        pickingTime = true
        field.stringValue = ""
        field.placeholderString = "Reminder time, e.g. 3pm or 9:30"
        view.window?.makeFirstResponder(field)
    }

    private func finish(_ choice: Choice) {
        popover?.close()
        onPick(choice)
    }

    // MARK: - Natural language

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if pickingTime, let time = Self.parseTime(field.stringValue) {
                let day = (current ?? Date()).startOfDay
                var at = TaskStore.combine(day: day, timeOf: time)
                if at < Date() && current == nil { at = at.addingDays(1) }
                finish(.reminder(at))
            } else if let choice = Self.parse(field.stringValue, mode: mode) {
                finish(choice)
            } else {
                NSSound.beep()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            popover?.close()
            return true
        }
        return false
    }

    /// Understands: today, tonight / this evening, tomorrow, someday, anytime,
    /// weekday names (mon, friday), "in 3 days", "in 2 weeks", "next week",
    /// a day number ("13"), "nov 13", "13 nov", and ISO dates.
    /// "3pm", "3:30 pm", "15:30", "9am", "9" (in time mode). Returns a date carrying the time.
    static func parseTime(_ raw: String, requireMarker: Bool = false) -> Date? {
        let text = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"^(?:at)?(\d{1,2})(?::(\d{2}))?(am|pm|a|p)?$"#),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hRange = Range(m.range(at: 1), in: text), var hour = Int(text[hRange]) else { return nil }
        let minute = Range(m.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let marker = Range(m.range(at: 3), in: text).map { String(text[$0]) }
        if requireMarker && marker == nil && m.range(at: 2).location == NSNotFound { return nil }
        if let marker {
            guard (1...12).contains(hour) else { return nil }
            if marker.hasPrefix("p") && hour < 12 { hour += 12 }
            if marker.hasPrefix("a") && hour == 12 { hour = 0 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
    }

    static func parse(_ raw: String, mode: Mode = .when) -> Choice? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // "tomorrow 3pm", "fri 9:30", "3pm": a trailing time makes it a reminder.
        if mode == .when {
            let words = text.split(separator: " ").map(String.init)
            for split in stride(from: words.count, through: 1, by: -1) {
                let timePart = words[(split - 1)...].joined(separator: " ")
                guard let time = parseTime(timePart, requireMarker: true) else { continue }
                let datePart = words[..<(split - 1)].joined(separator: " ")
                var day = Date().startOfDay
                if !datePart.isEmpty {
                    switch parse(datePart, mode: .when) {
                    case .date(let d)?: day = d
                    case .today?, .evening?: day = Date().startOfDay
                    default: return nil
                    }
                }
                var at = TaskStore.combine(day: day, timeOf: time)
                if datePart.isEmpty && at < Date() { at = at.addingDays(1) }
                return .reminder(at)
            }
        }
        let today = Date().startOfDay
        if "today".hasPrefix(text) && text.count >= 2 { return mode == .when ? .today : .date(today) }
        if ["tonight", "evening", "this evening"].contains(where: { $0.hasPrefix(text) && text.count >= 3 }) { return mode == .when ? .evening : .date(today) }
        if "tomorrow".hasPrefix(text) && text.count >= 3 { return .date(today.addingDays(1)) }
        if mode == .when, "someday".hasPrefix(text) && text.count >= 3 { return .someday }
        if mode == .when, "anytime".hasPrefix(text) && text.count >= 3 { return .anytime }
        if text.hasPrefix("next week") { return .date(nextWeekday(2, from: today, skipThisWeek: true)) }
        if text.hasPrefix("next month") { return .date(today.adding(.month, 1)) }
        if let regex = try? NSRegularExpression(pattern: #"^in (\d+) ?([a-z]*)$"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text) {
            let n = Int(text[numberRange]) ?? 0
            let unit = String(text[unitRange])
            if unit.hasPrefix("w") { return .date(today.addingDays(7 * n)) }
            if unit.hasPrefix("m") { return .date(today.adding(.month, n)) }
            if unit.hasPrefix("y") { return .date(today.adding(.year, n)) }
            return .date(today.addingDays(n))
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if text.count >= 2, let index = weekdays.firstIndex(where: { $0.hasPrefix(text) }) {
            return .date(nextWeekday(index + 1, from: today, skipThisWeek: false))
        }
        if let day = Int(text), (1...31).contains(day) {
            var components = Calendar.current.dateComponents([.year, .month], from: today)
            components.day = day
            if var date = Calendar.current.date(from: components) {
                if date < today { date = date.adding(.month, 1) }
                return .date(date)
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["MMM d", "MMMM d", "d MMM", "d MMMM", "yyyy-MM-dd", "M/d", "d/M"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) {
                var components = Calendar.current.dateComponents([.month, .day], from: parsed)
                if format.contains("yyyy") { return .date(parsed.startOfDay) }
                components.year = Calendar.current.component(.year, from: today)
                if var date = Calendar.current.date(from: components) {
                    if date < today { date = date.adding(.year, 1) }
                    return .date(date)
                }
            }
        }
        return nil
    }

    private static func nextWeekday(_ weekday: Int, from start: Date, skipThisWeek: Bool) -> Date {
        var date = start.addingDays(1)
        if skipThisWeek { date = start.addingDays(7 - ((Calendar.current.component(.weekday, from: start) + 5) % 7)) }
        while Calendar.current.component(.weekday, from: date) != weekday { date = date.addingDays(1) }
        return date
    }
}

private final class PickerRowButton: NSButton {
    private let handler: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, color: NSColor, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        image = NSImage.symbol(symbol, size: 13, weight: .semibold, color: color)
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        isBordered = false
        font = Fonts.medium(13)
        contentTintColor = Theme.text
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accent.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class DayButton: NSButton {
    private let handler: () -> Void
    private let isTodayCell: Bool
    private let isPastCell: Bool
    private let isSelectedCell: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, isToday: Bool, isPast: Bool, isSelected: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        isTodayCell = isToday
        isPastCell = isPast
        isSelectedCell = isSelected
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 1)
        if isSelectedCell {
            Theme.accent.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        } else if hovering && !isPastCell {
            Theme.accent.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = isSelectedCell ? .white : (isPastCell ? Theme.placeholder : (isTodayCell ? Theme.listColor(.today) : Theme.text))
        let attributes: [NSAttributedString.Key: Any] = [.font: Fonts.semibold(12.5), .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

extension WhenPicker.Choice {
    /// Applies a When choice to to-dos.
    func applyWhen(to ids: [String]) {
        let store = TaskStore.shared
        store.batch("When") {
            for id in ids {
                switch self {
                case .today: store.setBucket(id, bucket: .scheduled, date: Date().startOfDay)
                case .evening: store.setEvening(id, true)
                case .date(let date): store.setBucket(id, bucket: .scheduled, date: date)
                case .someday: store.setBucket(id, bucket: .someday)
                case .anytime, .clear: store.setBucket(id, bucket: .anytime)
                case .reminder(let at): store.setReminder(id, at: at)
                case .removeReminder: store.setReminder(id, at: nil)
                }
            }
        }
        if case .reminder = self { ReminderService.shared.requestAuthorization() }
    }

    func applyDeadline(to ids: [String]) {
        let store = TaskStore.shared
        store.batch("Deadline") {
            for id in ids {
                switch self {
                case .date(let date): store.setDeadline(id, date: date)
                case .today, .evening: store.setDeadline(id, date: Date().startOfDay)
                case .clear, .anytime, .someday, .removeReminder: store.setDeadline(id, date: nil)
                case .reminder(let at): store.setDeadline(id, date: at)
                }
            }
        }
    }
}

/// "Remind Me": quick reminder times plus a natural-language field
/// ("3pm", "tomorrow 9am", "fri 14:30", "in 20 min").
final class RemindPicker: NSViewController, NSTextFieldDelegate {
    private let current: Date?
    private let onPick: (Date?) -> Void
    private let field = NSTextField()
    private let hint = NSTextField.label("", font: Fonts.regular(11), color: Theme.secondary)
    private var popover: NSPopover?

    init(current: Date?, onPick: @escaping (Date?) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func show(current: Date?, relativeTo rect: NSRect, of view: NSView, onPick: @escaping (Date?) -> Void) {
        let picker = RemindPicker(current: current, onPick: onPick)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        picker.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        picker.view.window?.makeFirstResponder(picker.field)
    }

    private static func at(hour: Int, daysAhead: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date().startOfDay.addingDays(daysAhead))!
    }

    private var quickChoices: [(String, Date)] {
        let now = Date()
        var items: [(String, Date)] = [("In 15 minutes", now.addingTimeInterval(15 * 60)), ("In 1 hour", now.addingTimeInterval(3600))]
        let evening = Self.at(hour: 18, daysAhead: 0)
        if evening > now.addingTimeInterval(3600) { items.append(("This evening", evening)) }
        items.append(("Tomorrow morning", Self.at(hour: 9, daysAhead: 1)))
        var monday = Date().startOfDay.addingDays(1)
        while Calendar.current.component(.weekday, from: monday) != 2 { monday = monday.addingDays(1) }
        items.append(("Next week", Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: monday)!))
        return items
    }

    override func loadView() {
        let width: CGFloat = 270
        let root = FlippedView()
        var y: CGFloat = 12
        let title = NSTextField.label("Remind Me", font: Fonts.semibold(12.5), color: Theme.text)
        title.alignment = .center
        title.frame = NSRect(x: 12, y: y, width: width - 24, height: 18)
        root.addSubview(title)
        y += 26

        field.placeholderString = "3pm, tomorrow 9am, fri 14:30, in 20 min"
        field.font = Fonts.regular(13)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.frame = NSRect(x: 12, y: y, width: width - 24, height: 24)
        root.addSubview(field)
        y += 28
        hint.frame = NSRect(x: 14, y: y, width: width - 28, height: 15)
        root.addSubview(hint)
        y += 20

        let time = DateFormatter()
        time.timeStyle = .short
        let day = DateFormatter()
        day.dateFormat = "EEE"
        for (label, date) in quickChoices {
            let when = date.isToday ? time.string(from: date) : "\(day.string(from: date)) \(time.string(from: date))"
            let button = PickerRowButton(title: "\(label)  ·  \(when)", symbol: "bell.fill", color: Theme.accent) { [weak self] in self?.finish(date) }
            button.frame = NSRect(x: 8, y: y, width: width - 16, height: 26)
            root.addSubview(button)
            y += 28
        }
        if let current {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            let remove = PickerRowButton(title: "Remove Reminder (\(f.string(from: current)))", symbol: "bell.slash", color: Theme.secondary) { [weak self] in
                self?.finish(nil)
            }
            remove.frame = NSRect(x: 8, y: y, width: width - 16, height: 26)
            root.addSubview(remove)
            y += 28
        }
        y += 8
        root.frame = NSRect(x: 0, y: 0, width: width, height: y)
        preferredContentSize = root.frame.size
        view = root
    }

    /// "in 20 min", "in 2 hours", a bare time (today, or tomorrow once passed),
    /// or anything the When field understands with a time ("fri 3pm").
    static func parse(_ raw: String) -> Date? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let regex = try? NSRegularExpression(pattern: #"^in\s*(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?)$"#),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let amount = Range(m.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
           let unit = Range(m.range(at: 2), in: text).map({ String(text[$0]) }) {
            return Date().addingTimeInterval(TimeInterval(amount) * (unit.hasPrefix("h") ? 3600 : 60))
        }
        if let time = WhenPicker.parseTime(text) {
            return time > Date() ? time : time.addingDays(1)
        }
        if case .reminder(let at)? = WhenPicker.parse(text) { return at }
        return nil
    }

    func controlTextDidChange(_ obj: Notification) {
        if let date = Self.parse(field.stringValue) {
            let f = DateFormatter()
            f.dateFormat = date.isToday ? "'Today at' h:mm a" : "EEE d MMM 'at' h:mm a"
            hint.stringValue = f.string(from: date)
            hint.textColor = Theme.accent
        } else {
            hint.stringValue = field.stringValue.isEmpty ? "" : "Type a time, e.g. 4:30pm"
            hint.textColor = Theme.secondary
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let date = Self.parse(field.stringValue) { finish(date) } else { NSSound.beep() }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            popover?.close()
            return true
        }
        return false
    }

    private func finish(_ date: Date?) {
        popover?.close()
        onPick(date)
    }

    /// Sets (or clears) the reminder on to-dos and asks for notification permission the first time.
    static func apply(_ date: Date?, to ids: [String]) {
        let store = TaskStore.shared
        store.batch(date == nil ? "Remove Reminder" : "Remind Me") {
            for id in ids { store.setReminder(id, at: date) }
        }
        if date != nil { ReminderService.shared.requestAuthorization() }
    }
}
