import AppKit

// MARK: - Icons

enum WorkflowIcons {
    /// The open states, drawn the same way in checkboxes, menus and headers.
    /// Every shape is vertically symmetric, so it works in flipped and unflipped views.
    static func drawOpen(_ flow: Flow, in rect: NSRect, square: Bool, hovering: Bool = false, tint: NSColor = Theme.accent) {
        let radius = rect.width * 0.27
        let path = square ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) : NSBezierPath(ovalIn: rect)
        let color = flow == .todo ? (hovering ? Theme.secondary : Theme.checkboxStroke) : Theme.flowColor(flow)
        if hovering {
            tint.withAlphaComponent(0.12).setFill()
            path.fill()
        }
        color.setStroke()
        path.lineWidth = 1.3
        if flow == .backlog { path.setLineDash([2.2, 2.2], count: 2, phase: 0) }
        path.stroke()

        switch flow {
        case .progress:
            NSGraphicsContext.saveGraphicsState()
            let inner = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
            (square ? NSBezierPath(roundedRect: inner, xRadius: 1.2, yRadius: 1.2) : NSBezierPath(ovalIn: inner)).addClip()
            color.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .waiting:
            color.setFill()
            let barWidth = max(1.4, rect.width * 0.12), barHeight = rect.height * 0.42
            for offset in [-1.0, 1.0] {
                let x = rect.midX + CGFloat(offset) * barWidth * 1.15 - barWidth / 2
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
        default:
            break
        }
    }

    static func flowImage(_ flow: Flow, size: CGFloat = 14, square: Bool = true) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            let rect = bounds.insetBy(dx: 1, dy: 1)
            guard flow == .done || flow == .canceled else {
                drawOpen(flow, in: rect, square: square)
                return true
            }
            let radius = rect.width * 0.27
            let path = square ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) : NSBezierPath(ovalIn: rect)
            Theme.flowColor(flow).setFill()
            path.fill()
            let mark = NSBezierPath()
            if flow == .canceled {
                let inset = rect.width * 0.3
                mark.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
                mark.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
                mark.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
                mark.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
            } else {
                mark.move(to: NSPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.48))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.30))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.70))
            }
            mark.lineWidth = max(1.4, size * 0.12)
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            NSColor.white.setStroke()
            mark.stroke()
            return true
        }
    }

    /// Signal bars for Low / Medium / High, an orange badge for Urgent, three dots for none.
    static func priorityImage(_ priority: Priority, size: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            switch priority {
            case .urgent:
                Theme.urgent.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
                NSColor.white.setFill()
                let w = size * 0.13
                NSBezierPath(roundedRect: NSRect(x: bounds.midX - w / 2, y: size * 0.42, width: w, height: size * 0.36), xRadius: w / 2, yRadius: w / 2).fill()
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - w * 0.6, y: size * 0.2, width: w * 1.2, height: w * 1.2)).fill()
            case .none:
                Theme.tertiary.setFill()
                for index in 0..<3 {
                    NSBezierPath(roundedRect: NSRect(x: size * (0.12 + 0.3 * CGFloat(index)), y: bounds.midY - 0.8, width: size * 0.17, height: 1.6),
                                 xRadius: 0.8, yRadius: 0.8).fill()
                }
            default:
                for index in 0..<3 {
                    let lit = index < priority.rawValue
                    (lit ? Theme.secondary : Theme.tertiary.withAlphaComponent(0.45)).setFill()
                    let height = size * (0.32 + 0.21 * CGFloat(index))
                    NSBezierPath(roundedRect: NSRect(x: size * (0.1 + 0.3 * CGFloat(index)), y: size * 0.14, width: size * 0.2, height: height),
                                 xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
            return true
        }
    }
}

// MARK: - Menus

enum WorkflowMenus {
    private static var store: TaskStore { .shared }

    private static func item(_ title: String, image: NSImage?, key: String = "", checked: Bool, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, key: key, checked: checked, handler: handler)
        item.image = image
        return item
    }

    /// The six statuses (keys 1–6), plus what a single to-do is waiting on.
    static func status(for ids: [String], done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let tasks = ids.compactMap { store.task($0) }.filter(\.isTodo)
        let single = tasks.count == 1 ? tasks.first : nil
        let all: [Flow] = [.backlog, .todo, .progress, .waiting, .done, .canceled]
        for (index, flow) in all.enumerated() {
            menu.addItem(item(flow.title, image: WorkflowIcons.flowImage(flow), key: "\(index + 1)", checked: single?.flow == flow) {
                store.batch("Set Status") { tasks.forEach { store.setFlow($0.id, flow) } }
                done()
            })
        }
        if let single, single.isOpen {
            menu.addItem(.separator())
            let waiting = NSMenuItem(title: "Waiting On", action: nil, keyEquivalent: "")
            waiting.submenu = self.waiting(for: single, done: done)
            menu.addItem(waiting)
        }
        return menu
    }

    static func waiting(for task: TaskItem, done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let siblings: [TaskItem] = task.projectID.map { projectID in
            store.children(of: projectID).filter { $0.isTodo && $0.isOpen && $0.id != task.id && $0.blockedBy != task.id }
        } ?? []
        if !siblings.isEmpty {
            let label = NSMenuItem(title: "Blocked by a to-do", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            for sibling in siblings.prefix(12) {
                let title = sibling.title.count > 44 ? String(sibling.title.prefix(44)) + "…" : sibling.title
                menu.addItem(item(title, image: WorkflowIcons.flowImage(sibling.flow), checked: task.blockedBy == sibling.id) {
                    store.setWaiting(task.id, blockedBy: sibling.id)
                    done()
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Someone or Something Else…", checked: task.stage == .waiting && task.waitingOn != nil) {
            if let text = Prompt.text(title: "What are you waiting on?", message: "A person, a reply, a delivery.",
                                      placeholder: "Henry", initial: task.waitingOn ?? "", button: "Set") {
                store.setWaiting(task.id, on: text)
            }
            done()
        })
        if task.stage == .waiting {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("No Longer Waiting") {
                store.setStage(task.id, .todo)
                done()
            })
        }
        return menu
    }

    static func priority(for ids: [String], done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let tasks = ids.compactMap { store.task($0) }.filter(\.isTodo)
        let single = tasks.count == 1 ? tasks.first : nil
        for priority in Priority.allCases.reversed() {
            menu.addItem(item(priority.title, image: WorkflowIcons.priorityImage(priority), key: "\(priority.rawValue)",
                              checked: single?.priority == priority) {
                store.batch("Set Priority") { tasks.forEach { store.setPriority($0.id, priority) } }
                done()
            })
        }
        return menu
    }

    static func estimate(for ids: [String], done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let tasks = ids.compactMap { store.task($0) }.filter(\.isTodo)
        let single = tasks.count == 1 ? tasks.first : nil
        for minutes in [15, 30, 60, 120, 240, 480] {
            menu.addItem(ClosureMenuItem(Duration.text(seconds: minutes * 60), checked: single?.estimate == minutes) {
                store.batch("Set Estimate") { tasks.forEach { store.setEstimate($0.id, minutes: minutes) } }
                done()
            })
        }
        menu.addItem(ClosureMenuItem("Other…") {
            let initial = single.flatMap { $0.estimate > 0 ? "\($0.estimate)" : nil } ?? ""
            if let text = Prompt.text(title: "Estimate", message: "Minutes, or hours like 1.5h.", placeholder: "90", initial: initial, button: "Set"),
               let minutes = parseMinutes(text) {
                store.batch("Set Estimate") { tasks.forEach { store.setEstimate($0.id, minutes: minutes) } }
            }
            done()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("No Estimate", checked: single?.estimate == 0) {
            store.batch("Set Estimate") { tasks.forEach { store.setEstimate($0.id, minutes: 0) } }
            done()
        })
        return menu
    }

    /// "90", "90m", "1.5h", "1h 30m" → minutes.
    static func parseMinutes(_ raw: String) -> Int? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let minutes = Int(text) { return minutes }
        var total = 0.0
        var number = ""
        var matched = false
        for character in text {
            if character.isNumber || character == "." { number.append(character); continue }
            guard let value = Double(number) else { number = ""; continue }
            if character == "h" { total += value * 60; matched = true; number = "" }
            else if character == "m" { total += value; matched = true; number = "" }
        }
        if let value = Double(number), matched { total += value }
        return matched ? Int(total.rounded()) : nil
    }

    static func projectStatus(for id: String) -> NSMenu {
        let menu = NSMenu()
        guard let project = store.task(id) else { return menu }
        for stage in [Stage.todo, .backlog, .waiting] {
            let current = project.stage == stage || (stage == .todo && project.stage == .progress)
            menu.addItem(ClosureMenuItem(stage.projectTitle, checked: current) {
                var updated = project
                updated.stage = stage
                store.update(updated)
            })
        }
        return menu
    }
}

// MARK: - View options

enum ListLayout: String { case list, board, table }

enum ListGrouping: String {
    case sections, status, priority, project, none

    var title: String {
        switch self {
        case .sections: return "Headings"
        case .status: return "Status"
        case .priority: return "Priority"
        case .project: return "Project"
        case .none: return "None"
        }
    }
}

enum ListFilter: String, CaseIterable {
    case all, open, high, today, deadline

    var title: String {
        switch self {
        case .all: return "All To-Dos"
        case .open: return "Hide Done"
        case .high: return "High Priority"
        case .today: return "Planned for Today"
        case .deadline: return "Has a Deadline"
        }
    }

    func matches(_ task: TaskItem) -> Bool {
        switch self {
        case .all: return true
        case .open: return task.isOpen
        case .high: return task.priority.rawValue >= Priority.high.rawValue
        case .today: return task.isDueToday
        case .deadline: return task.deadline != nil
        }
    }
}

struct ViewOptions: Equatable {
    var layout: ListLayout
    var grouping: ListGrouping
    var filter: ListFilter

    /// Projects, areas and Active remember their own layout, grouping and filter.
    static func key(for selection: Selection) -> String? {
        switch selection {
        case .project(let id): return "project:" + id
        case .area(let id): return "area:" + id
        case .builtin(.active): return "active"
        default: return nil
        }
    }

    static func groupings(for selection: Selection) -> [ListGrouping] {
        switch selection {
        case .project: return [.status, .sections, .priority, .none]
        case .area: return [.project, .status, .priority, .none]
        default: return [.status, .project, .priority, .none]
        }
    }

    static func load(for selection: Selection) -> ViewOptions {
        var options: ViewOptions
        switch selection {
        case .project(let id):
            // A project organised with headings keeps them until told otherwise.
            let hasHeadings = TaskStore.shared.headings(of: id).contains(where: \.isOpen)
            options = ViewOptions(layout: .list, grouping: hasHeadings ? .sections : .status, filter: .all)
        case .area:
            options = ViewOptions(layout: .list, grouping: .project, filter: .all)
        default:
            options = ViewOptions(layout: .list, grouping: .status, filter: .all)
        }
        // Snapshots choose a view without touching saved preferences.
        let env = ProcessInfo.processInfo.environment
        if env["THINGS4_SNAP_LAYOUT"] != nil || env["THINGS4_SNAP_GROUP"] != nil {
            if let layout = env["THINGS4_SNAP_LAYOUT"].flatMap(ListLayout.init(rawValue:)), selection != .builtin(.active) { options.layout = layout }
            if let grouping = env["THINGS4_SNAP_GROUP"].flatMap(ListGrouping.init(rawValue:)) { options.grouping = grouping }
            return options
        }
        guard let key = key(for: selection),
              let parts = UserDefaults.standard.string(forKey: "view." + key)?.split(separator: "|").map(String.init), parts.count == 3 else { return options }
        if let layout = ListLayout(rawValue: parts[0]), selection != .builtin(.active) { options.layout = layout }
        if let grouping = ListGrouping(rawValue: parts[1]), groupings(for: selection).contains(grouping) { options.grouping = grouping }
        if let filter = ListFilter(rawValue: parts[2]) { options.filter = filter }
        return options
    }

    func save(for selection: Selection) {
        guard let key = Self.key(for: selection) else { return }
        UserDefaults.standard.set("\(layout.rawValue)|\(grouping.rawValue)|\(filter.rawValue)", forKey: "view." + key)
    }
}

/// Blocks that span the window instead of the reading column.
protocol WideBlock: NSView {
    func preferredHeight(width: CGFloat) -> CGFloat
}

// MARK: - Options bar

/// List / Board / Table on the left, Filter and Group on the right.
final class ViewOptionsBar: FlippedView {
    var onLayout: ((ListLayout) -> Void)?
    var onFilter: ((NSView) -> Void)?
    var onGroup: ((NSView) -> Void)?

    private let options: ViewOptions
    private let showsLayouts: Bool
    private var segments: [(layout: ListLayout, rect: NSRect)] = []
    private let filterButton: FlatButton
    private let groupButton: FlatButton

    init(options: ViewOptions, showsLayouts: Bool) {
        self.options = options
        self.showsLayouts = showsLayouts
        let filtered = options.filter != .all
        filterButton = FlatButton(title: filtered ? options.filter.title : "Filter", symbol: "line.3.horizontal.decrease",
                                  color: filtered ? Theme.accent : Theme.secondary, fontSize: 12)
        groupButton = FlatButton(title: "Group: " + options.grouping.title, symbol: "rectangle.grid.1x2", color: Theme.secondary, fontSize: 12)
        super.init(frame: .zero)
        filterButton.target = self
        filterButton.action = #selector(filterTapped)
        groupButton.target = self
        groupButton.action = #selector(groupTapped)
        addSubview(filterButton)
        groupButton.isHidden = options.layout != .list
        addSubview(groupButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func filterTapped() { onFilter?(filterButton) }
    @objc private func groupTapped() { onGroup?(groupButton) }

    private static let items: [(ListLayout, String, String)] = [
        (.list, "List", "list.bullet"), (.board, "Board", "rectangle.split.3x1"), (.table, "Table", "tablecells")
    ]

    private func attributes(selected: Bool) -> [NSAttributedString.Key: Any] {
        [.font: Fonts.medium(12), .foregroundColor: selected ? Theme.text : Theme.secondary]
    }

    override func layout() {
        super.layout()
        var x = bounds.width
        for button in [groupButton, filterButton] where !button.isHidden {
            let width = button.intrinsicContentSize.width + 14
            x -= width
            button.frame = NSRect(x: x, y: 2, width: width, height: 24)
            x -= 4
        }
        segments.removeAll()
        guard showsLayouts else { return }
        var segmentX: CGFloat = 2
        for (layout, title, _) in Self.items {
            let width = ceil((title as NSString).size(withAttributes: attributes(selected: true)).width) + 36
            segments.append((layout, NSRect(x: segmentX, y: 2, width: width, height: 24)))
            segmentX += width + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsLayouts, let last = segments.last else { return }
        Theme.tagBackground.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: last.rect.maxX + 2, height: 28), xRadius: 7, yRadius: 7).fill()
        for (index, segment) in segments.enumerated() {
            let selected = segment.layout == options.layout
            if selected {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                Theme.cardElevated.setFill()
                NSBezierPath(roundedRect: segment.rect, xRadius: 5.5, yRadius: 5.5).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let (_, title, symbol) = Self.items[index]
            let color = selected ? Theme.text : Theme.secondary
            NSImage.symbol(symbol, size: 11, weight: .medium, color: color)?
                .draw(in: NSRect(x: segment.rect.minX + 9, y: segment.rect.minY + 6, width: 13, height: 12))
            let size = (title as NSString).size(withAttributes: attributes(selected: selected))
            (title as NSString).draw(at: NSPoint(x: segment.rect.minX + 27, y: segment.rect.midY - size.height / 2),
                                     withAttributes: attributes(selected: selected))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = segments.first(where: { $0.rect.contains(point) }), hit.layout != options.layout { onLayout?(hit.layout) }
    }
}

// MARK: - Group header

/// "▾ ◐ In Progress 2 … +": a collapsible status or priority group.
final class StatusGroupHeader: HoverRowView {
    override var isFlipped: Bool { true }
    var onToggle: (() -> Void)?
    var onAdd: (() -> Void)?

    private let title: String
    private let count: Int
    private let image: NSImage?
    private let collapsed: Bool
    private let addButton = IconButton(symbol: "plus", size: 11, color: Theme.secondary, tooltip: "New To-Do")

    init(title: String, count: Int, image: NSImage?, collapsed: Bool, canAdd: Bool) {
        self.title = title
        self.count = count
        self.image = image
        self.collapsed = collapsed
        super.init(frame: .zero)
        if canAdd {
            addButton.target = self
            addButton.action = #selector(addTapped)
            addButton.isHidden = true
            addSubview(addButton)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHovered: Bool { didSet { addButton.isHidden = !isHovered } }

    @objc private func addTapped() { onAdd?() }

    override func layout() {
        super.layout()
        addButton.frame = NSRect(x: bounds.width - 24, y: bounds.height - 27, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let baseline = bounds.height - 25
        NSImage.symbol(collapsed ? "chevron.right" : "chevron.down", size: 8, weight: .bold, color: Theme.tertiary)?
            .draw(in: NSRect(x: 0, y: baseline + 4, width: 9, height: 9))
        var x: CGFloat = 16
        if let image {
            image.draw(in: NSRect(x: x, y: baseline + 1.5, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            x += 21
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Fonts.semibold(13), .foregroundColor: Theme.text]
        (title as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: attributes)
        x += ceil((title as NSString).size(withAttributes: attributes).width) + 8
        ("\(count)" as NSString).draw(at: NSPoint(x: x, y: baseline + 0.5),
                                      withAttributes: [.font: Fonts.regular(12.5), .foregroundColor: Theme.tertiary])
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
}

// MARK: - Stats

/// The chips under a project or area title, and a project's three-colour progress bar.
final class WorkflowStatsView: FlippedView {
    struct Chip {
        let image: NSImage?
        let strong: String
        let text: String
        var action: ((NSView) -> Void)? = nil
    }

    private let chips: [Chip]
    private var chipRects: [NSRect] = []
    /// Done, in progress and waiting as fractions of all to-dos; nil hides the bar.
    private let bar: (done: Double, progress: Double, waiting: Double)?
    private let barLabel: String

    init(chips: [Chip], bar: (done: Double, progress: Double, waiting: Double)? = nil, barLabel: String = "") {
        self.chips = chips
        self.bar = bar
        self.barLabel = barLabel
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func height(hasBar: Bool) -> CGFloat { hasBar ? 48 : 26 }

    private let strongAttributes: [NSAttributedString.Key: Any] = [.font: Fonts.medium(12), .foregroundColor: Theme.text]
    private let textAttributes: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12), .foregroundColor: Theme.secondary]

    override func draw(_ dirtyRect: NSRect) {
        chipRects.removeAll()
        var x: CGFloat = 0
        for chip in chips {
            let strongWidth = ceil((chip.strong as NSString).size(withAttributes: strongAttributes).width)
            let textWidth = chip.text.isEmpty ? 0 : ceil((chip.text as NSString).size(withAttributes: textAttributes).width) + 4
            let width = 10 + (chip.image == nil ? 0 : 17) + strongWidth + textWidth + 10
            let rect = NSRect(x: x, y: 0, width: width, height: 24)
            chipRects.append(rect)
            guard rect.maxX <= bounds.width else { break }
            Theme.tagBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            var textX = x + 10
            if let image = chip.image {
                image.draw(in: NSRect(x: textX, y: 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
                textX += 17
            }
            (chip.strong as NSString).draw(at: NSPoint(x: textX, y: 4.5), withAttributes: strongAttributes)
            if !chip.text.isEmpty {
                (chip.text as NSString).draw(at: NSPoint(x: textX + strongWidth + 4, y: 4.5), withAttributes: textAttributes)
            }
            x += width + 6
        }

        guard let bar else { return }
        let labelWidth = ceil((barLabel as NSString).size(withAttributes: textAttributes).width)
        let track = NSRect(x: 0, y: 39, width: bounds.width - labelWidth - 12, height: 4)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).addClip()
        Theme.separator.setFill()
        track.fill()
        var barX = track.minX
        for (fraction, flow) in [(bar.done, Flow.done), (bar.progress, .progress), (bar.waiting, .waiting)] {
            let width = track.width * CGFloat(fraction)
            Theme.flowColor(flow).setFill()
            NSRect(x: barX, y: track.minY, width: width, height: track.height).fill()
            barX += width
        }
        NSGraphicsContext.restoreGraphicsState()
        (barLabel as NSString).draw(at: NSPoint(x: bounds.width - labelWidth, y: 33), withAttributes: textAttributes)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = chipRects.firstIndex(where: { $0.contains(point) }), index < chips.count, let action = chips[index].action else {
            super.mouseDown(with: event)
            return
        }
        let anchor = FlippedView(frame: chipRects[index])
        addSubview(anchor)
        action(anchor)
        anchor.removeFromSuperview()
    }
}

/// A horizontal scroller that lets vertical scrolling pass to the list around it.
final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
