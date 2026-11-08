import AppKit

final class SidebarRowView: HoverRowView {
    var isSelectedRow = false {
        didSet { needsDisplay = true }
    }
    var isDropTarget = false {
        didSet { needsDisplay = true }
    }
    var onSelect: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    /// Called with the dragged task IDs when to-dos are dropped on this row.
    var onDropTasks: (([String]) -> Void)?

    private let iconView = NSImageView()
    private let dotView = ProgressRing()
    private let titleLabel: NSTextField
    private let countLabel = NSTextField.label("", font: Fonts.regular(11), color: Theme.tertiary)
    private let indent: CGFloat
    private let isDot: Bool
    private let badgeLabel = NSTextField.label("", font: Fonts.semibold(10.5), color: .white)
    private var badge = 0

    init(title: String, symbol: String?, color: NSColor, count: Int?, indent: CGFloat = 0, isDot: Bool = false,
         progress: Double = 0, badge: Int = 0, bold: Bool = false) {
        self.indent = indent
        self.isDot = isDot
        self.badge = badge
        self.titleLabel = NSTextField.label(title, font: bold ? Fonts.semibold(14.5) : Fonts.medium(14.5), color: Theme.text)
        super.init(frame: .zero)
        if badge > 0 {
            badgeLabel.stringValue = "\(badge)"
            badgeLabel.alignment = .center
            addSubview(badgeLabel)
        }

        if isDot {
            dotView.color = color
            dotView.progress = progress
            addSubview(dotView)
        } else {
            if let symbol {
                iconView.image = NSImage.symbol(symbol, size: 13, weight: .medium, color: color)
            }
            addSubview(iconView)
        }

        addSubview(titleLabel)
        if let count, count > 0 {
            countLabel.stringValue = "\(count)"
            addSubview(countLabel)
        }
        registerForDraggedTypes([TaskDrag.type])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var badgeFrame: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        defer {
            if badge > 0 {
                Theme.deadline.setFill()
                NSBezierPath(roundedRect: badgeFrame, xRadius: 8.5, yRadius: 8.5).fill()
            }
        }
        let rect = NSRect(x: 11, y: 0, width: bounds.width - 22, height: bounds.height)
        if isDropTarget {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            Theme.accent.withAlphaComponent(0.18).setFill()
            path.fill()
            Theme.accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else if isSelectedRow {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            Theme.sidebarSelection.setFill()
            path.fill()
        } else if isHovered {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            Theme.sidebarHover.setFill()
            path.fill()
        }
    }

    override func layout() {
        super.layout()
        let x = 18 + indent
        if isDot {
            dotView.frame = NSRect(x: x - 1, y: (bounds.height - 16) / 2, width: 16, height: 16)
        } else {
            iconView.frame = NSRect(x: x - 3, y: (bounds.height - 21) / 2, width: 21, height: 21)
        }
        // Things: text starts 40pt from the sidebar edge.
        titleLabel.frame = NSRect(x: x + 22, y: (bounds.height - 18) / 2, width: bounds.width - x - 64, height: 18)
        let countWidth = countLabel.fittingWidth
        countLabel.frame = NSRect(x: bounds.width - countWidth - 20, y: (bounds.height - 15) / 2, width: countWidth, height: 15)
        if badge > 0 {
            let width = max(18, badgeLabel.fittingWidth + 6)
            let right = countLabel.superview == nil ? bounds.width - 16 : countLabel.frame.minX - 6
            badgeFrame = NSRect(x: right - width, y: (bounds.height - 17) / 2, width: width, height: 17)
            badgeLabel.frame = badgeFrame.insetBy(dx: 0, dy: 1.5)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    // MARK: - Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropTasks != nil else { return [] }
        isDropTarget = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let ids = TaskDrag.read(sender.draggingPasteboard)
        guard !ids.isEmpty, let onDropTasks else { return false }
        onDropTasks(ids)
        return true
    }
}

final class SidebarViewController: NSViewController {
    let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let footer = FlippedView(fill: Theme.sidebar)
    private let newListButton = FlatButton(title: "New List", symbol: "plus", color: Theme.secondary, fontSize: 12.5)
    private let settingsButton = IconButton(symbol: "slider.horizontal.3", size: 13, color: Theme.secondary, tooltip: "Settings (⌘,)")
    private let aiButton = IconButton(symbol: "sparkles", size: 13, color: Theme.accent, tooltip: "AI sidebar (⇧⌘A)")
    private var rowsHeight: CGFloat = 0

    override func loadView() {
        let root = FlippedView(fill: Theme.sidebar)
        view = root

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        root.addSubview(scrollView)

        root.addSubview(footer)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        aiButton.target = self
        aiButton.action = #selector(toggleAI)
        newListButton.target = self
        newListButton.action = #selector(newListTapped)
        newListButton.alignment = .left
        footer.addSubview(newListButton)
        footer.addSubview(settingsButton)
        footer.addSubview(aiButton)

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .storeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .selectionDidChange, object: state)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .preferencesChanged, object: nil)

        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayout() {
        super.viewDidLayout()
        scrollView.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - 36))
        footer.frame = NSRect(x: 0, y: max(0, view.bounds.height - 36), width: view.bounds.width, height: 36)
        newListButton.frame = NSRect(x: 16, y: 7, width: 110, height: 22)
        settingsButton.frame = NSRect(x: view.bounds.width - 38, y: 6, width: 24, height: 24)
        aiButton.frame = NSRect(x: view.bounds.width - 66, y: 6, width: 24, height: 24)
        layoutRows()
    }

    @objc private func reload() {
        aiButton.isHidden = !Preferences.aiEnabled
        documentView.removeAllSubviews()
        buildRows()
        layoutRows()
    }

    private func addRow(_ row: NSView, _ y: inout CGFloat, height: CGFloat = 24) {
        row.frame = NSRect(x: 0, y: y, width: 240, height: height)
        documentView.addSubview(row)
        y += height
    }

    private func listRow(_ list: BuiltinList) -> SidebarRowView {
        let store = TaskStore.shared
        let count = store.count(for: list)
        var badge = 0
        if list == .today {
            badge = store.tasks(in: .builtin(.today)).filter { ($0.deadline.map { $0 < Date().startOfDay.addingDays(1) } ?? false) }.count
        }
        // Things: the red badge counts overdue/due-today items, the grey number the rest.
        let shown = list == .today ? count - badge : count
        let showCount = (list == .inbox || list == .today || list == .trash) && shown > 0
        let row = SidebarRowView(title: list.title, symbol: list.symbol, color: Theme.listColor(list),
                                 count: showCount ? shown : nil, badge: badge)
        row.isSelectedRow = state.selection == .builtin(list)
        row.onContextMenu = { event in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Open in New Window", symbol: "macwindow.badge.plus") {
                MainWindowController.openNew(selection: .builtin(list))
            })
            NSMenu.popUpContextMenu(menu, with: event, for: row)
        }
        row.onSelect = { self.state.selection = .builtin(list) }
        switch list {
        case .logbook: break
        case .trash:
            row.onDropTasks = { ids in store.batch("Delete") { ids.forEach { store.moveToTrash($0) } } }
            row.onContextMenu = { event in
                let menu = NSMenu()
                let item = ClosureMenuItem("Empty Trash…", symbol: "trash") {
                    (MainWindowController.active ?? .shared).root.listVC.emptyTrashAction(nil)
                }
                item.isEnabled = count > 0
                menu.addItem(item)
                NSMenu.popUpContextMenu(menu, with: event, for: row)
            }
        default:
            row.onDropTasks = { ids in
                store.batch("Move") {
                    for id in ids where store.task(id)?.isTodo == true {
                        switch list {
                        case .inbox: store.move(id, toProject: nil, areaID: nil); store.setBucket(id, bucket: .inbox)
                        case .today: store.setBucket(id, bucket: .scheduled, date: Date().startOfDay)
                        case .upcoming: store.setBucket(id, bucket: .scheduled, date: Date().startOfDay.addingDays(1))
                        case .anytime: store.setBucket(id, bucket: .anytime)
                        case .someday: store.setBucket(id, bucket: .someday)
                        default: break
                        }
                    }
                }
            }
        }
        return row
    }

    /// Things layout: Inbox / Today Upcoming Anytime Someday / Logbook Trash /
    /// loose projects / each area with its projects / tags.
    private func buildRows() {
        var y: CGFloat = 32
        let store = TaskStore.shared

        addRow(listRow(.inbox), &y)
        y += 16
        for list in [BuiltinList.today, .upcoming, .anytime, .someday] { addRow(listRow(list), &y) }
        y += 16
        addRow(listRow(.logbook), &y)
        // Things only lists the Trash while it has something in it.
        if store.count(for: .trash) > 0 { addRow(listRow(.trash), &y) }

        let loose = store.projects(inArea: nil).filter(\.isOpen)
        if !loose.isEmpty {
            y += 16
            for project in loose { addRow(projectSidebarRow(project, indent: 0), &y) }
        }

        for area in store.areas.sorted(by: { $0.index < $1.index }) {
            y += 16
            let row = SidebarRowView(title: area.title, symbol: "things.area.plain", color: Theme.secondary,
                                     count: nil, indent: 0, bold: true)
            row.isSelectedRow = state.selection == .area(area.id)
            row.onSelect = { self.state.selection = .area(area.id) }
            row.onContextMenu = { [weak self] event in self?.areaMenu(area, event: event, row: row) }
            row.onDropTasks = { ids in
                store.batch("Move") {
                    for id in ids {
                        guard let item = store.task(id) else { continue }
                        if item.isProject {
                            var project = item
                            project.areaID = area.id
                            store.update(project)
                        } else if item.isTodo {
                            store.move(id, toProject: nil, areaID: area.id)
                        }
                    }
                }
            }
            addRow(row, &y)
            for project in store.projects(inArea: area.id) where project.isOpen {
                addRow(projectSidebarRow(project, indent: 0), &y)
            }
        }

        let tags: [String] = [] // Things has no tags in the sidebar (use the tag filter or Quick Find).
        if !tags.isEmpty {
            y += 16
            let header = FlippedView()
            let label = NSTextField.label("TAGS", font: Fonts.semibold(10.5), color: Theme.tertiary)
            label.frame = NSRect(x: 18, y: 6, width: 140, height: 14)
            header.addSubview(label)
            addRow(header, &y, height: 22)
            for tag in tags {
                let row = SidebarRowView(title: tag, symbol: "tag", color: Theme.tertiary, count: nil, indent: 0)
                row.isSelectedRow = state.selection == .tag(tag)
                row.onSelect = { self.state.selection = .tag(tag) }
                row.onDropTasks = { ids in
                    store.batch("Tag") { for id in ids { if let item = store.task(id) { store.setTags(id, item.tags + [tag]) } } }
                }
                addRow(row, &y)
            }
        }
        y += 20
        documentView.frame = NSRect(x: 0, y: 0, width: max(240, scrollView.contentSize.width), height: max(y, scrollView.contentSize.height))
        rowsHeight = y
    }

    @objc private func newListTapped() {
        let controller = NewListPopover { [weak self] isProject in
            if isProject { self?.addProject() } else { self?.addArea() }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.popover = popover
        popover.show(relativeTo: newListButton.bounds, of: newListButton, preferredEdge: .maxY)
    }

    private func projectSidebarRow(_ project: TaskItem, indent: CGFloat) -> SidebarRowView {
        let store = TaskStore.shared
        let progress = store.projectProgress(project.id)
        let ratio = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
        let row = SidebarRowView(title: project.title, symbol: nil,
                                 color: Theme.secondary, count: nil,
                                 indent: indent, isDot: true, progress: ratio)
        row.isSelectedRow = state.selection == .project(project.id)
        row.onSelect = { self.state.selection = .project(project.id) }
        row.onContextMenu = { [weak self] event in self?.projectMenu(project, event: event, row: row) }
        row.onDropTasks = { ids in
            store.batch("Move") {
                for id in ids where store.task(id)?.isTodo == true {
                    store.move(id, toProject: project.id, areaID: project.areaID)
                }
            }
        }
        return row
    }

    private func projectMenu(_ project: TaskItem, event: NSEvent, row: NSView) {
        let store = TaskStore.shared
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open in New Window", symbol: "macwindow.badge.plus") {
            MainWindowController.openNew(selection: .project(project.id))
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename…", symbol: "pencil") {
            if let title = Prompt.text(title: "Rename Project", message: "", placeholder: "Project", initial: project.title, button: "Rename") {
                store.renameProject(project.id, to: title)
            }
        })
        menu.addItem(ClosureMenuItem("Complete Project", symbol: "checkmark.circle") {
            if Prompt.confirm(title: "Complete “\(project.title)”?", message: "Open to-dos in it will be completed as well.", button: "Complete") {
                store.toggleCompletion(project.id)
                if self.state.selection == .project(project.id) { self.state.selection = .builtin(.logbook) }
            }
        })
        menu.addItem(ClosureMenuItem("Duplicate", symbol: "plus.square.on.square") {
            store.duplicate(project.id)
        })
        let moveItem = NSMenuItem(title: "Move to Area", action: nil, keyEquivalent: "")
        moveItem.image = NSImage.symbol("square.grid.2x2", size: 12, weight: .regular, color: Theme.secondary)
        let moveMenu = NSMenu()
        moveMenu.addItem(ClosureMenuItem("No Area", checked: project.areaID == nil) {
            var updated = project; updated.areaID = nil; store.update(updated)
        })
        for area in store.areas {
            moveMenu.addItem(ClosureMenuItem(area.title, checked: project.areaID == area.id) {
                var updated = project; updated.areaID = area.id; store.update(updated)
            })
        }
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete Project", symbol: "trash") {
            store.moveToTrash(project.id)
            if self.state.selection == .project(project.id) { self.state.selection = .builtin(.today) }
        })
        NSMenu.popUpContextMenu(menu, with: event, for: row)
    }

    private func areaMenu(_ area: Area, event: NSEvent, row: NSView) {
        let store = TaskStore.shared
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open in New Window", symbol: "macwindow.badge.plus") {
            MainWindowController.openNew(selection: .area(area.id))
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename…", symbol: "pencil") {
            if let title = Prompt.text(title: "Rename Area", message: "", placeholder: "Area", initial: area.title, button: "Rename") {
                store.renameArea(area.id, to: title)
            }
        })
        menu.addItem(ClosureMenuItem("New Project in Area…", symbol: "plus") {
            if let title = Prompt.text(title: "New Project", message: "Name this project.", placeholder: "Project name") {
                let project = store.createProject(title: title, areaID: area.id)
                self.state.selection = .project(project.id)
            }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete Area", symbol: "trash") {
            let projects = store.projects(inArea: area.id).count
            let message = projects > 0 ? "Its \(projects) project\(projects == 1 ? "" : "s") and to-dos are kept and moved out of the area."
                                       : "Its to-dos are kept."
            if Prompt.confirm(title: "Delete “\(area.title)”?", message: message, button: "Delete") {
                store.deleteArea(area.id)
                if self.state.selection == .area(area.id) { self.state.selection = .builtin(.today) }
            }
        })
        NSMenu.popUpContextMenu(menu, with: event, for: row)
    }

    private func sectionHeader(title: String, addTarget: Selector?) -> NSView {
        let container = SidebarSectionHeader(title: title)
        if let addTarget {
            container.addButton.target = self
            container.addButton.action = addTarget
            container.addButton.toolTip = "New \(title.dropLast())"
            container.onContextMenu = { [weak self] event in
                let menu = NSMenu()
                menu.addItem(ClosureMenuItem("New \(title.dropLast())…", symbol: "plus") {
                    _ = self?.perform(addTarget)
                })
                NSMenu.popUpContextMenu(menu, with: event, for: container)
            }
        } else {
            container.addButton.isHidden = true
        }
        return container
    }

    private func layoutRows() {
        let width = scrollView.contentSize.width
        guard width > 10 else { return }
        for subview in documentView.subviews {
            let frame = subview.frame
            if frame.width < 200 { continue }
            subview.frame = NSRect(x: 0, y: frame.origin.y, width: width, height: frame.height)
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width,
                                    height: max(rowsHeight + 12, scrollView.contentSize.height))
    }

    override func rightMouseDown(with event: NSEvent) {
        newListTapped()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc private func toggleAI() {
        NotificationCenter.default.post(name: .aiPanelToggle, object: nil)
    }

    @objc fileprivate func addProject() {
        if let title = Prompt.text(title: "New Project", message: "Name this project.", placeholder: "Project name") {
            let project = TaskStore.shared.createProject(title: title)
            state.selection = .project(project.id)
        }
    }

    @objc fileprivate func addArea() {
        if let title = Prompt.text(title: "New Area", message: "Name this area.", placeholder: "Area name") {
            let area = TaskStore.shared.createArea(title: title)
            state.selection = .area(area.id)
        }
    }
}


/// "AREAS  +" style header. Lays out its own button so it never drifts.
final class SidebarSectionHeader: FlippedView {
    let addButton = IconButton(symbol: "plus", size: 11, color: Theme.secondary, tooltip: nil)
    var onContextMenu: ((NSEvent) -> Void)?
    private let label: NSTextField

    init(title: String) {
        label = NSTextField.label(title.uppercased(), font: Fonts.semibold(10.5), color: Theme.tertiary)
        super.init(frame: .zero)
        addSubview(label)
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 18, y: 9, width: 140, height: 14)
        addButton.frame = NSRect(x: bounds.width - 32, y: 4, width: 20, height: 20)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }
}

extension SidebarViewController {
    func debugAddProject() { addProject() }
}

/// "+ New List": New Project / New Area with Things' descriptions.
final class NewListPopover: NSViewController {
    weak var popover: NSPopover?
    private let onPick: (Bool) -> Void

    init(onPick: @escaping (Bool) -> Void) {
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = FlippedView()
        let project = OptionRow(symbol: "circle.lefthalf.filled", color: Theme.accent, title: "New Project",
                                detail: "Define a goal, then work towards it one to-do at a time.") { [weak self] in self?.pick(true) }
        let area = OptionRow(symbol: "shippingbox", color: Theme.success, title: "New Area",
                             detail: "Group your projects and to-dos based on different responsibilities, such as Family or Work.") { [weak self] in self?.pick(false) }
        project.frame = NSRect(x: 6, y: 6, width: 308, height: 64)
        let line = FillView(fill: Theme.separator)
        line.frame = NSRect(x: 12, y: 74, width: 296, height: 1)
        area.frame = NSRect(x: 6, y: 80, width: 308, height: 80)
        [project, line, area].forEach(root.addSubview)
        root.frame = NSRect(x: 0, y: 0, width: 320, height: 166)
        preferredContentSize = root.frame.size
        view = root
    }

    private func pick(_ isProject: Bool) {
        popover?.close()
        DispatchQueue.main.async { self.onPick(isProject) }
    }
}

private final class OptionRow: NSView {
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private let title = NSTextField.label("", font: Fonts.semibold(14), color: Theme.text)
    private let detail = NSTextField.wrappingLabel("", font: Fonts.regular(12.5), color: Theme.secondary)
    private let icon = NSImageView()
    override var isFlipped: Bool { true }

    init(symbol: String, color: NSColor, title text: String, detail info: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        icon.image = NSImage.symbol(symbol, size: 14, weight: .semibold, color: color)
        title.stringValue = text
        detail.stringValue = info
        [icon, title, detail].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 10, width: 18, height: 18)
        title.frame = NSRect(x: 36, y: 9, width: bounds.width - 46, height: 20)
        detail.frame = NSRect(x: 36, y: 30, width: bounds.width - 46, height: bounds.height - 34)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { action() }
    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.rowHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }
}
