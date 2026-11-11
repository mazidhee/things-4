import AppKit

/// What a board card or table row can ask its list to do.
struct TaskActions {
    var select: (TaskItem, NSEvent) -> Void = { _, _ in }
    var open: (TaskItem, NSView) -> Void = { _, _ in }
    var toggle: (TaskItem, Bool) -> Void = { _, _ in }
    var contextMenu: (TaskItem, NSEvent) -> Void = { _, _ in }
    var dragIDs: (String) -> [String] = { [$0] }
}

extension TaskDrag {
    /// Starts dragging to-dos from any view, with a picture of that view under the pointer.
    static func begin(_ ids: [String], from view: NSView & NSDraggingSource, event: NSEvent) {
        let item = NSPasteboardItem()
        item.setData((try? JSONSerialization.data(withJSONObject: ids)) ?? Data(), forType: type)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        draggingItem.setDraggingFrame(view.bounds, contents: image)
        let session = view.beginDraggingSession(with: [draggingItem], event: event, source: view)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

private func metaText(_ task: TaskItem) -> (left: [String], time: String?, deadline: String?) {
    var left: [String] = []
    if !task.checklist.isEmpty { left.append("\(task.checklistDone)/\(task.checklist.count)") }
    left.append(contentsOf: task.tags.prefix(2))
    let tracked = TaskStore.shared.trackedTime(task.id)
    var time: String?
    if task.estimate > 0 {
        time = Duration.text(seconds: tracked) + " / " + Duration.text(seconds: task.estimate * 60)
    } else if tracked >= 60 {
        time = Duration.text(seconds: tracked)
    }
    return (left, time, task.deadline.map(\.monthDayString))
}

// MARK: - Card

final class BoardCardView: HoverRowView, NSDraggingSource {
    override var isFlipped: Bool { true }
    let task: TaskItem
    var actions = TaskActions()
    var isSelectedCard = false { didSet { needsDisplay = true } }

    let checkbox = CheckboxView()
    private var mouseDownPoint: NSPoint?
    private let waiting: String?

    private static let titleFont = Fonts.regular(13.5)
    private static let smallFont = Fonts.regular(11.5)

    init(task: TaskItem) {
        self.task = task
        waiting = TaskStore.shared.waitingLabel(task)
        super.init(frame: .zero)
        checkbox.isSquare = true
        checkbox.isChecked = task.isCompleted
        checkbox.isCanceled = task.isCanceled
        checkbox.flow = task.flow
        checkbox.onToggle = { [weak self] alternate in
            guard let self else { return }
            self.actions.toggle(self.task, alternate)
        }
        addSubview(checkbox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func hasMeta(_ task: TaskItem) -> Bool {
        let meta = metaText(task)
        return task.priority != .none || !meta.left.isEmpty || meta.time != nil || meta.deadline != nil
    }

    private static func titleHeight(_ task: TaskItem, width: CGFloat) -> CGFloat {
        let rect = (task.title as NSString).boundingRect(with: NSSize(width: width - 42, height: 60),
                                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                         attributes: [.font: titleFont])
        return max(17, ceil(rect.height))
    }

    static func height(for task: TaskItem, width: CGFloat) -> CGFloat {
        var height = 10 + titleHeight(task, width: width)
        if TaskStore.shared.waitingLabel(task) != nil { height += 17 }
        if hasMeta(task) { height += 23 }
        return height + 10
    }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 11, y: 11.5, width: 14, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if isHovered && !isSelectedCard {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            Theme.boardCard.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Theme.boardCard.setFill()
            path.fill()
        }
        (isSelectedCard ? Theme.accent : Theme.boardCardBorder).setStroke()
        path.lineWidth = isSelectedCard ? 1.5 : 1
        path.stroke()

        let width = bounds.width
        let titleHeight = Self.titleHeight(task, width: width)
        var titleAttributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: task.isCompleted ? Theme.secondary : Theme.text]
        if task.isCanceled { titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let title = task.title.trimmingCharacters(in: .whitespaces).isEmpty ? "New To-Do" : task.title
        (title as NSString).draw(with: NSRect(x: 33, y: 9, width: width - 42, height: titleHeight),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttributes)
        var y = 10 + titleHeight
        if let waiting {
            (waiting as NSString).draw(with: NSRect(x: 33, y: y + 1, width: width - 42, height: 15), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                       attributes: [.font: Self.smallFont, .foregroundColor: Theme.flowColor(.waiting)])
            y += 17
        }
        guard Self.hasMeta(task) else { return }
        y += 7
        let meta = metaText(task)
        let small: [NSAttributedString.Key: Any] = [.font: Self.smallFont, .foregroundColor: Theme.secondary]
        var right = width - 11
        if let deadline = meta.deadline {
            let urgent = task.isOpen && (task.deadline?.isPast == true || task.deadline?.isToday == true)
            let attributes: [NSAttributedString.Key: Any] = [.font: Fonts.medium(11.5), .foregroundColor: task.isOpen ? Theme.deadline : Theme.secondary]
            let size = (deadline as NSString).size(withAttributes: attributes)
            right -= size.width
            (deadline as NSString).draw(at: NSPoint(x: right, y: y), withAttributes: attributes)
            right -= 14
            NSImage.symbol(urgent ? "flag.fill" : "flag", size: 9, weight: .semibold, color: task.isOpen ? Theme.deadline : Theme.secondary)?
                .draw(in: NSRect(x: right, y: y + 2, width: 11, height: 11))
            right -= 9
        }
        if let time = meta.time {
            let size = (time as NSString).size(withAttributes: small)
            right -= size.width
            (time as NSString).draw(at: NSPoint(x: right, y: y), withAttributes: small)
            // On a narrow card the clock gives way to the priority bars.
            if right - 14 > 34 {
                right -= 14
                NSImage.symbol("clock", size: 9, weight: .medium, color: Theme.tertiary)?.draw(in: NSRect(x: right, y: y + 2, width: 11, height: 11))
            }
            right -= 8
        }
        var x: CGFloat = 11
        if task.priority != .none {
            WorkflowIcons.priorityImage(task.priority).draw(in: NSRect(x: x, y: y + 0.5, width: 14, height: 14), from: .zero,
                                                            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 21
        }
        for text in meta.left {
            let size = (text as NSString).size(withAttributes: small)
            guard x + size.width < right else { break }
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: small)
            x += size.width + 9
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { actions.open(task, self) } else { actions.select(task, event) }
    }

    override func rightMouseDown(with event: NSEvent) { actions.contextMenu(task, event) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        TaskDrag.begin(actions.dragIDs(task.id), from: self, event: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

// MARK: - Board

/// Five status columns. An area's board adds one row of columns per project.
final class BoardView: FlippedView, WideBlock {
    struct Lane {
        let projectID: String?
        let title: String?
        let tasks: [TaskItem]
    }

    var actions = TaskActions() { didSet { cards.values.forEach { $0.actions = actions } } }
    var onMove: (([String], Flow) -> Void)?
    var onAdd: ((Flow) -> Void)?
    var onLane: ((String) -> Void)?
    private(set) var cards: [String: BoardCardView] = [:]

    private let lanes: [Lane]
    private let scroll = HorizontalScrollView()
    private let content = BoardContentView()
    private static let gap: CGFloat = 12
    private static let flows = Flow.boardOrder

    /// Card IDs in reading order: down each column, lane by lane.
    var orderedIDs: [String] {
        lanes.flatMap { lane in Self.flows.flatMap { flow in lane.tasks.filter { $0.flow == flow }.map(\.id) } }
    }

    init(lanes: [Lane]) {
        self.lanes = lanes
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = content
        addSubview(scroll)
        for task in lanes.flatMap(\.tasks) {
            let card = BoardCardView(task: task)
            cards[task.id] = card
            content.addSubview(card)
        }
        content.onColumnDrop = { [weak self] ids, flow in self?.onMove?(ids, flow) }
        content.onAdd = { [weak self] flow in self?.onAdd?(flow) }
        content.onLane = { [weak self] id in self?.onLane?(id) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func columnWidth(for width: CGFloat) -> CGFloat {
        max(168, floor((width - Self.gap * 4) / 5))
    }

    /// Places every card and returns the board's height.
    @discardableResult
    private func arrange(width: CGFloat) -> CGFloat {
        let column = columnWidth(for: width)
        let solo = lanes.count == 1 && lanes[0].title == nil
        var heads: [BoardContentView.Head] = []
        let all = lanes.flatMap(\.tasks)
        for (index, flow) in Self.flows.enumerated() {
            let items = all.filter { $0.flow == flow }
            heads.append(.init(flow: flow, count: items.count, estimate: TaskStore.shared.estimateTotal(items.filter(\.isOpen)),
                               x: CGFloat(index) * (column + Self.gap)))
        }
        var y: CGFloat = 34
        var laneHeaders: [BoardContentView.LaneHeader] = []
        var addLinks: [BoardContentView.AddLink] = []
        for lane in lanes {
            if let title = lane.title {
                laneHeaders.append(.init(projectID: lane.projectID, title: title, open: lane.tasks.filter(\.isOpen).count, y: y))
                y += 40
            }
            var tallest: CGFloat = solo ? 220 : 40
            for (index, flow) in Self.flows.enumerated() {
                let x = CGFloat(index) * (column + Self.gap)
                var cardY = y
                for task in lane.tasks where task.flow == flow {
                    let height = BoardCardView.height(for: task, width: column)
                    cards[task.id]?.frame = NSRect(x: x, y: cardY, width: column, height: height)
                    cardY += height + 6
                }
                if solo && flow != .done {
                    addLinks.append(.init(flow: flow, rect: NSRect(x: x, y: cardY, width: column, height: 26)))
                    cardY += 30
                }
                tallest = max(tallest, cardY - y)
            }
            y += tallest + 6
        }
        content.columnWidth = column
        content.heads = heads
        content.laneHeaders = laneHeaders
        content.addLinks = addLinks
        let contentWidth = column * 5 + Self.gap * 4
        content.frame = NSRect(x: 0, y: 0, width: contentWidth, height: y)
        content.needsDisplay = true
        return y + 14
    }

    func preferredHeight(width: CGFloat) -> CGFloat { arrange(width: width) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        arrange(width: bounds.width)
    }
}

final class BoardContentView: FlippedView {
    struct Head { let flow: Flow; let count: Int; let estimate: Int; let x: CGFloat }
    struct LaneHeader { let projectID: String?; let title: String; let open: Int; let y: CGFloat }
    struct AddLink { let flow: Flow; let rect: NSRect }

    var columnWidth: CGFloat = 200
    var heads: [Head] = []
    var laneHeaders: [LaneHeader] = []
    var addLinks: [AddLink] = []
    var onColumnDrop: (([String], Flow) -> Void)?
    var onAdd: ((Flow) -> Void)?
    var onLane: ((String) -> Void)?
    private var dropFlow: Flow? { didSet { if dropFlow != oldValue { needsDisplay = true } } }
    private var hoverAdd: Flow? { didSet { if hoverAdd != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TaskDrag.type])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverAdd = addLinks.first { $0.rect.contains(point) }?.flow
    }

    override func mouseExited(with event: NSEvent) { hoverAdd = nil }

    override func draw(_ dirtyRect: NSRect) {
        let strong: [NSAttributedString.Key: Any] = [.font: Fonts.semibold(13), .foregroundColor: Theme.text]
        let faint: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12.5), .foregroundColor: Theme.tertiary]
        for head in heads {
            if head.flow == dropFlow {
                let rect = NSRect(x: head.x - 5, y: 28, width: columnWidth + 10, height: bounds.height - 30)
                let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
                Theme.accent.withAlphaComponent(0.07).setFill()
                path.fill()
                Theme.accent.withAlphaComponent(0.45).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            WorkflowIcons.flowImage(head.flow).draw(in: NSRect(x: head.x + 2, y: 5, width: 14, height: 14), from: .zero,
                                                    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let title = head.flow.title as NSString
            title.draw(at: NSPoint(x: head.x + 23, y: 3.5), withAttributes: strong)
            ("\(head.count)" as NSString).draw(at: NSPoint(x: head.x + 23 + title.size(withAttributes: strong).width + 7, y: 4), withAttributes: faint)
            if head.estimate > 0 {
                let text = Duration.text(seconds: head.estimate * 60) as NSString
                text.draw(at: NSPoint(x: head.x + columnWidth - text.size(withAttributes: faint).width - 2, y: 4), withAttributes: faint)
            }
        }
        for lane in laneHeaders {
            Theme.separator.setFill()
            NSRect(x: 0, y: lane.y, width: bounds.width, height: 1).fill()
            let title = lane.title as NSString
            title.draw(at: NSPoint(x: 2, y: lane.y + 12), withAttributes: strong)
            ("\(lane.open) open" as NSString).draw(at: NSPoint(x: 2 + title.size(withAttributes: strong).width + 8, y: lane.y + 12.5), withAttributes: faint)
        }
        for link in addLinks {
            if hoverAdd == link.flow {
                Theme.rowHover.setFill()
                NSBezierPath(roundedRect: link.rect, xRadius: 7, yRadius: 7).fill()
            }
            ("+ New To-Do" as NSString).draw(at: NSPoint(x: link.rect.minX + 9, y: link.rect.minY + 5),
                                             withAttributes: [.font: Fonts.regular(12.5), .foregroundColor: hoverAdd == link.flow ? Theme.secondary : Theme.tertiary])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let link = addLinks.first(where: { $0.rect.contains(point) }) { onAdd?(link.flow); return }
        if let lane = laneHeaders.first(where: { point.y >= $0.y && point.y < $0.y + 38 }), let id = lane.projectID { onLane?(id); return }
        super.mouseDown(with: event)
    }

    private func flow(at sender: NSDraggingInfo) -> Flow? {
        let x = convert(sender.draggingLocation, from: nil).x
        return heads.first { x >= $0.x - 6 && x < $0.x + columnWidth + 6 }?.flow
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !TaskDrag.read(sender.draggingPasteboard).isEmpty else { return [] }
        dropFlow = flow(at: sender)
        return dropFlow == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropFlow = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ids = TaskDrag.read(sender.draggingPasteboard)
        let target = flow(at: sender)
        dropFlow = nil
        guard let target, !ids.isEmpty else { return false }
        onColumnDrop?(ids, target)
        return true
    }
}

// MARK: - Table

final class TableRowView: HoverRowView, NSDraggingSource {
    enum Cell { case status, priority, estimate }

    override var isFlipped: Bool { true }
    let task: TaskItem
    var actions = TaskActions()
    var onCell: ((Cell, TaskItem, NSView, NSRect) -> Void)?
    var isSelectedRow = false { didSet { needsDisplay = true } }
    var columns: [TaskTableView.Column] = [] { didSet { needsDisplay = true } }

    private let checkbox = CheckboxView()
    private var mouseDownPoint: NSPoint?
    private var hoverCell: TaskTableView.Column.Kind? { didSet { if hoverCell != oldValue { needsDisplay = true } } }

    init(task: TaskItem) {
        self.task = task
        super.init(frame: .zero)
        checkbox.isSquare = true
        checkbox.isChecked = task.isCompleted
        checkbox.isCanceled = task.isCanceled
        checkbox.flow = task.flow
        checkbox.onToggle = { [weak self] alternate in
            guard let self else { return }
            self.actions.toggle(self.task, alternate)
        }
        addSubview(checkbox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let kind = column(at: convert(event.locationInWindow, from: nil))?.kind
        hoverCell = [.status, .priority, .estimate].contains(kind) ? kind : nil
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverCell = nil
    }

    private func column(at point: NSPoint) -> TaskTableView.Column? {
        columns.first { point.x >= $0.x - 4 && point.x < $0.x + $0.width }
    }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedRow {
            Theme.rowSelection.setFill()
            bounds.fill()
        } else if isHovered {
            Theme.rowHover.setFill()
            bounds.fill()
        }
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let store = TaskStore.shared
        let muted: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12.5), .foregroundColor: Theme.secondary]
        let midY = bounds.height / 2
        func text(_ value: String, in column: TaskTableView.Column, attributes: [NSAttributedString.Key: Any], alignRight: Bool = false) {
            let size = (value as NSString).size(withAttributes: attributes)
            let x = alignRight ? column.x + column.width - min(size.width, column.width) - 8 : column.x
            (value as NSString).draw(with: NSRect(x: x, y: midY - size.height / 2, width: column.width - 8, height: size.height),
                                     options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes)
        }
        for column in columns {
            if column.kind == hoverCell {
                Theme.text.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: NSRect(x: column.x - 6, y: 4, width: column.width - 4, height: bounds.height - 9), xRadius: 5, yRadius: 5).fill()
            }
            switch column.kind {
            case .title:
                var attributes: [NSAttributedString.Key: Any] = [.font: Fonts.regular(13.5), .foregroundColor: task.isCompleted ? Theme.secondary : Theme.text]
                if task.isCanceled { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                var title = task.title.isEmpty ? "New To-Do" : task.title
                if let waiting = store.waitingLabel(task) { title += "   " + waiting }
                let string = NSMutableAttributedString(string: title, attributes: attributes)
                if let waiting = store.waitingLabel(task) {
                    string.addAttributes([.font: Fonts.regular(11.5), .foregroundColor: Theme.flowColor(.waiting)],
                                         range: NSRange(location: (title as NSString).length - (waiting as NSString).length, length: (waiting as NSString).length))
                }
                let size = string.size()
                string.draw(with: NSRect(x: column.x + 30, y: midY - size.height / 2, width: column.width - 40, height: size.height),
                            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            case .status:
                let color = Theme.flowColor(task.flow)
                let attributes: [NSAttributedString.Key: Any] = [.font: Fonts.medium(11.5), .foregroundColor: color.blended(withFraction: 0.45, of: Theme.text) ?? color]
                let size = (task.flow.title as NSString).size(withAttributes: attributes)
                let pill = NSRect(x: column.x, y: midY - 10.5, width: size.width + 18, height: 21)
                color.withAlphaComponent(0.17).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 10.5, yRadius: 10.5).fill()
                (task.flow.title as NSString).draw(at: NSPoint(x: pill.minX + 9, y: midY - size.height / 2), withAttributes: attributes)
            case .priority:
                WorkflowIcons.priorityImage(task.priority).draw(in: NSRect(x: column.x, y: midY - 7, width: 14, height: 14), from: .zero,
                                                                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                if task.priority != .none {
                    var shifted = column
                    shifted.x += 21
                    shifted.width -= 21
                    text(task.priority.title, in: shifted, attributes: muted)
                }
            case .project:
                if let project = task.projectID.flatMap({ store.task($0) }) { text(project.title, in: column, attributes: muted) }
            case .when:
                text(ThingsAPI.whenLabel(task).capitalized, in: column, attributes: muted)
            case .deadline:
                if let deadline = task.deadline {
                    text("⚑ " + deadline.monthDayString, in: column,
                         attributes: [.font: Fonts.medium(12), .foregroundColor: task.isOpen ? Theme.deadline : Theme.secondary])
                }
            case .estimate:
                text(task.estimate > 0 ? Duration.text(seconds: task.estimate * 60) : "—", in: column,
                     attributes: task.estimate > 0 ? muted : [.font: Fonts.regular(12.5), .foregroundColor: Theme.tertiary], alignRight: true)
            case .focused:
                let tracked = store.trackedTime(task.id)
                if tracked >= 60 { text(Duration.text(seconds: tracked), in: column, attributes: muted, alignRight: true) }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        if let column = column(at: point), event.clickCount == 1, task.status != .trashed {
            let rect = NSRect(x: column.x, y: 0, width: column.width, height: bounds.height)
            switch column.kind {
            case .status: actions.select(task, event); onCell?(.status, task, self, rect); return
            case .priority: actions.select(task, event); onCell?(.priority, task, self, rect); return
            case .estimate: actions.select(task, event); onCell?(.estimate, task, self, rect); return
            default: break
            }
        }
        if event.clickCount == 2 { actions.open(task, self) } else { actions.select(task, event) }
    }

    override func rightMouseDown(with event: NSEvent) { actions.contextMenu(task, event) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        TaskDrag.begin(actions.dragIDs(task.id), from: self, event: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// Every to-do as a row of properties, with totals underneath.
final class TaskTableView: FlippedView, WideBlock {
    struct Column {
        enum Kind { case title, status, priority, project, when, deadline, estimate, focused }
        let kind: Kind
        var x: CGFloat
        var width: CGFloat

        var title: String {
            switch kind {
            case .title: return "To-Do"
            case .status: return "Status"
            case .priority: return "Priority"
            case .project: return "Project"
            case .when: return "When"
            case .deadline: return "Deadline"
            case .estimate: return "Estimate"
            case .focused: return "Focused"
            }
        }
    }

    var actions = TaskActions() { didSet { rows.values.forEach { $0.actions = actions } } }
    var onCell: ((TableRowView.Cell, TaskItem, NSView, NSRect) -> Void)? { didSet { rows.values.forEach { $0.onCell = onCell } } }
    private(set) var rows: [String: TableRowView] = [:]
    let orderedIDs: [String]

    private let tasks: [TaskItem]
    private let showProject: Bool
    private var columns: [Column] = []
    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 32
    private static let footerHeight: CGFloat = 36

    init(tasks: [TaskItem], showProject: Bool) {
        self.tasks = tasks
        self.showProject = showProject
        orderedIDs = tasks.map(\.id)
        super.init(frame: .zero)
        for task in tasks {
            let row = TableRowView(task: task)
            rows[task.id] = row
            addSubview(row)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func preferredHeight(width: CGFloat) -> CGFloat {
        Self.headerHeight + CGFloat(tasks.count) * Self.rowHeight + Self.footerHeight
    }

    /// Fixed-width property columns on the right; the title takes what is left.
    /// Narrow windows drop When, then Project, before the title gets cramped.
    private func columns(for width: CGFloat) -> [Column] {
        var fixed: [(Column.Kind, CGFloat)] = [(.status, 118), (.priority, 104)]
        if showProject { fixed.append((.project, 150)) }
        fixed += [(.when, 96), (.deadline, 92), (.estimate, 84), (.focused, 84)]
        func total() -> CGFloat { fixed.reduce(0) { $0 + $1.1 } }
        for droppable in [Column.Kind.when, .project] where width - total() < 240 {
            fixed.removeAll { $0.0 == droppable }
        }
        var result = [Column(kind: .title, x: 0, width: max(160, width - total()))]
        var x = result[0].width
        for (kind, columnWidth) in fixed {
            result.append(Column(kind: kind, x: x, width: columnWidth))
            x += columnWidth
        }
        return result
    }

    override func layout() {
        super.layout()
        columns = columns(for: bounds.width)
        var y = Self.headerHeight
        for task in tasks {
            guard let row = rows[task.id] else { continue }
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            row.columns = columns
            y += Self.rowHeight
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let header: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12), .foregroundColor: Theme.tertiary]
        let footer: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12), .foregroundColor: Theme.secondary]
        for column in columns {
            let title = column.title as NSString
            let right = column.kind == .estimate || column.kind == .focused
            let x = right ? column.x + column.width - title.size(withAttributes: header).width - 8 : column.x + (column.kind == .title ? 8 : 0)
            title.draw(at: NSPoint(x: x, y: 8), withAttributes: header)
        }
        Theme.separator.setFill()
        NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill()

        let y = Self.headerHeight + CGFloat(tasks.count) * Self.rowHeight + 10
        let count = tasks.count == 1 ? "1 to-do" : "\(tasks.count) to-dos"
        (count as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: footer)
        let store = TaskStore.shared
        let sums: [Column.Kind: Int] = [.estimate: store.estimateTotal(tasks) * 60, .focused: store.trackedTotal(tasks)]
        for column in columns {
            guard let seconds = sums[column.kind], seconds > 0 else { continue }
            let text = Duration.text(seconds: seconds) as NSString
            text.draw(at: NSPoint(x: column.x + column.width - text.size(withAttributes: footer).width - 8, y: y), withAttributes: footer)
        }
    }
}

// MARK: - Editor popover

/// The to-do card in a popover, for layouts that have no row to expand in place.
final class TaskEditorPopover: NSObject, NSPopoverDelegate {
    private static var current: TaskEditorPopover?

    private let popover = NSPopover()
    private let editor: TaskEditorView
    private let container = FlippedView(fill: nil)
    private let taskID: String
    private static let width: CGFloat = 470

    static func show(taskID: String, from view: NSView) {
        guard let task = TaskStore.shared.task(taskID), task.isTodo, view.window != nil else { return }
        current?.popover.close()
        let presenter = TaskEditorPopover(task: task)
        current = presenter
        presenter.popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        DispatchQueue.main.async { presenter.editor.focus(.title) }
    }

    private init(task: TaskItem) {
        taskID = task.id
        editor = TaskEditorView(task: task)
        super.init()
        let controller = NSViewController()
        controller.view = container
        container.addSubview(editor)
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.delegate = self
        editor.onClose = { [weak self] in self?.popover.close() }
        editor.onReload = { [weak self] in self?.refresh() }
        editor.onHeightChange = { [weak self] in self?.resize() }
        resize()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .storeDidChange, object: nil)
    }

    @objc private func refresh() {
        guard let task = TaskStore.shared.task(taskID), task.status != .trashed else {
            popover.close()
            return
        }
        editor.update(task: task)
        resize()
    }

    private func resize() {
        let inner = Self.width - 36
        let height = editor.preferredHeight(width: inner)
        let size = NSSize(width: Self.width, height: height + 22)
        container.frame = NSRect(origin: .zero, size: size)
        editor.frame = NSRect(x: 18, y: 14, width: inner, height: height)
        editor.needsLayout = true
        popover.contentSize = size
    }

    func popoverWillClose(_ notification: Notification) {
        editor.commitAll()
    }

    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // Like the inline card: a new to-do that was never filled in goes away.
        if let task = TaskStore.shared.task(taskID), task.title == "New To-Do" || task.title.isEmpty, task.notes.isEmpty,
           task.checklist.isEmpty, task.tags.isEmpty, Date().timeIntervalSince(task.createdAt) < 3600 {
            TaskStore.shared.deletePermanently(taskID)
        }
        if Self.current === self { Self.current = nil }
    }
}
