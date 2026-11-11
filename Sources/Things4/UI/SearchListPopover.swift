import AppKit

/// A Things-style popover: a search field on top and a filterable list of rows.
/// Used for Move (⇧⌘M) and Tags (⇧⌘T).
final class SearchListPopover: NSViewController, NSTextFieldDelegate {
    struct Row {
        var title: String
        var symbol: String
        var color: NSColor
        var checked: Bool = false
        var indent: Bool = false
        var bold: Bool = false
        var separatorBefore: Bool = false
        var subtitle: String? = nil
        var action: () -> Void
    }

    private let placeholder: String
    private let allRows: [Row]
    private var visible: [Row] = []
    private var highlighted = 0
    private let field = NSTextField()
    private let list = FlippedView()
    private let footer: (title: String, action: () -> Void)?
    private var popover: NSPopover?
    private let keepsOpen: Bool
    /// When set, rows come from this search function instead of filtering `allRows`.
    var provider: ((String) -> [Row])?
    var rowLimit = 60
    private let rowHeight: CGFloat = 28
    var width: CGFloat = 280

    init(placeholder: String, rows: [Row], footer: (String, () -> Void)? = nil, keepsOpen: Bool = false) {
        self.placeholder = placeholder
        self.allRows = rows
        self.footer = footer.map { (title: $0.0, action: $0.1) }
        self.keepsOpen = keepsOpen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setInitialQuery(_ text: String) {
        _ = view
        field.stringValue = text
        reload()
    }

    static func show(_ controller: SearchListPopover, relativeTo rect: NSRect, of view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        controller.view.window?.makeFirstResponder(controller.field)
    }

    override func loadView() {
        let root = FlippedView()
        field.placeholderString = placeholder
        field.font = Fonts.regular(13)
        field.alignment = .center
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        root.addSubview(field)
        root.addSubview(list)
        view = root
        reload()
    }

    private func reload() {
        let query = field.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        if let provider {
            visible = Array(provider(query).prefix(rowLimit))
        } else {
            visible = query.isEmpty ? allRows : allRows.filter { $0.title.lowercased().contains(query) }
        }
        highlighted = min(highlighted, max(0, visible.count - 1))
        list.removeAllSubviews()
        var y: CGFloat = 0
        for (index, row) in visible.enumerated() {
            if row.separatorBefore && query.isEmpty && index > 0 {
                let line = FillView(fill: Theme.separator)
                line.frame = NSRect(x: 8, y: y + 4, width: width - 16, height: 1)
                list.addSubview(line)
                y += 9
            }
            let rowView = PopoverRow(row: row, highlighted: index == highlighted) { [weak self] in self?.choose(index) }
            let h = row.subtitle == nil ? rowHeight : rowHeight + 14
            rowView.frame = NSRect(x: 6, y: y, width: width - 12, height: h)
            list.addSubview(rowView)
            y += h
        }
        if let footer {
            let button = NSButton(title: footer.title, target: self, action: #selector(footerTapped))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 10, y: y + 8, width: width - 20, height: 28)
            list.addSubview(button)
            y += 44
        }
        field.frame = NSRect(x: 12, y: 10, width: width - 24, height: 20)
        let listHeight = min(y, 420)
        list.frame = NSRect(x: 0, y: 38, width: width, height: y)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 38 + listHeight + 6)
        preferredContentSize = view.frame.size
    }

    @objc private func footerTapped() {
        popover?.close()
        footer?.action()
    }

    private func choose(_ index: Int) {
        guard index < visible.count else { return }
        let row = visible[index]
        if !keepsOpen { popover?.close() }
        row.action()
    }

    func controlTextDidChange(_ obj: Notification) {
        highlighted = 0
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            highlighted = min(visible.count - 1, highlighted + 1); reload(); return true
        case #selector(NSResponder.moveUp(_:)):
            highlighted = max(0, highlighted - 1); reload(); return true
        case #selector(NSResponder.insertNewline(_:)):
            choose(highlighted); return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover?.close(); return true
        default:
            return false
        }
    }
}

private final class PopoverRow: NSView {
    private let row: SearchListPopover.Row
    private let highlighted: Bool
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(row: SearchListPopover.Row, highlighted: Bool, action: @escaping () -> Void) {
        self.row = row
        self.highlighted = highlighted
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        let active = highlighted || hovering
        if active {
            Theme.accent.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let x: CGFloat = row.indent ? 30 : 10
        if let image = NSImage.symbol(row.symbol, size: 13, weight: .medium, color: active ? .white : row.color) {
            image.draw(in: NSRect(x: x, y: 6, width: 16, height: 16))
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: row.bold ? Fonts.semibold(13.5) : Fonts.medium(13.5),
            .foregroundColor: active ? NSColor.white : Theme.text
        ]
        (row.title as NSString).draw(with: NSRect(x: x + 24, y: 5, width: bounds.width - x - 60, height: 20),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        if let subtitle = row.subtitle {
            let sub: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12), .foregroundColor: active ? NSColor.white.withAlphaComponent(0.8) : Theme.secondary]
            (subtitle as NSString).draw(with: NSRect(x: x + 24, y: 23, width: bounds.width - x - 60, height: 16),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: sub)
        }
        if row.checked, let check = NSImage.symbol("checkmark", size: 12, weight: .semibold, color: active ? .white : Theme.accent) {
            check.draw(in: NSRect(x: bounds.width - 26, y: 7, width: 14, height: 14))
        }
    }
}

extension SearchListPopover {
    /// Things' Move popover.
    static func move(ids: [String], done: @escaping () -> Void) -> SearchListPopover {
        let store = TaskStore.shared
        let items = ids.compactMap { store.task($0) }
        let single = items.count == 1 ? items.first : nil
        let onlyTodos = items.allSatisfy(\.isTodo)
        var rows: [Row] = []
        rows.append(Row(title: "Inbox", symbol: "tray.fill", color: Theme.listColor(.inbox),
                        checked: single.map { $0.bucket == .inbox && $0.projectID == nil && $0.areaID == nil } ?? false) {
            store.batch("Move") { ids.forEach { store.move($0, toProject: nil, areaID: nil); store.setBucket($0, bucket: .inbox) } }
            done()
        })
        rows.append(Row(title: "No Project", symbol: "xmark", color: Theme.secondary,
                        checked: single.map { $0.projectID == nil && $0.areaID == nil && $0.bucket != .inbox } ?? false) {
            store.batch("Move") { ids.forEach { store.move($0, toProject: nil, areaID: nil) } }
            done()
        })
        let loose = store.projects(inArea: nil).filter(\.isOpen)
        for (index, project) in loose.enumerated() where onlyTodos {
            rows.append(Row(title: project.title, symbol: "circle", color: Theme.accent, checked: single?.projectID == project.id,
                            separatorBefore: index == 0) {
                store.batch("Move") { ids.forEach { store.move($0, toProject: project.id, areaID: project.areaID) } }
                done()
            })
        }
        for area in store.areas.sorted(by: { $0.index < $1.index }) {
            rows.append(Row(title: area.title, symbol: "shippingbox", color: Theme.success,
                            checked: single.map { $0.areaID == area.id && $0.projectID == nil } ?? false, bold: true, separatorBefore: true) {
                store.batch("Move") {
                    for id in ids {
                        if var project = store.task(id), project.isProject { project.areaID = area.id; store.update(project) }
                        else { store.move(id, toProject: nil, areaID: area.id) }
                    }
                }
                done()
            })
            guard onlyTodos else { continue }
            for project in store.projects(inArea: area.id) where project.isOpen {
                rows.append(Row(title: project.title, symbol: "circle", color: Theme.accent, checked: single?.projectID == project.id) {
                    store.batch("Move") { ids.forEach { store.move($0, toProject: project.id, areaID: project.areaID) } }
                    done()
                })
            }
        }
        return SearchListPopover(placeholder: "Move", rows: rows)
    }

    /// Things' Tags popover. Default tags are offered even before first use.
    static func tags(ids: [String], done: @escaping () -> Void) -> SearchListPopover {
        let store = TaskStore.shared
        let items = ids.compactMap { store.task($0) }
        let defaults = ["Errand", "Home", "Office", "Important", "Pending"]
        var names = defaults
        for tag in store.knownTags where !names.contains(tag) { names.append(tag) }
        var rows: [Row] = names.map { tag in
            let all = !items.isEmpty && items.allSatisfy { $0.tags.contains(tag) }
            return Row(title: tag, symbol: "tag.fill", color: store.tagTint(tag) ?? Theme.secondary, checked: all) {
                store.batch("Tags") {
                    for item in items {
                        guard let fresh = store.task(item.id) else { continue }
                        var tags = Set(fresh.tags)
                        if all { tags.remove(tag) } else { tags.insert(tag) }
                        store.setTags(item.id, Array(tags))
                    }
                }
                done()
            }
        }
        rows.append(Row(title: "Edit Tags & Colors…", symbol: "paintpalette", color: Theme.secondary, separatorBefore: true) {
            TagManagerWindowController.shared.showWindow(nil)
        })
        rows.append(Row(title: "New Tag…", symbol: "plus", color: Theme.secondary) {
            if let value = Prompt.text(title: "New Tag", message: "", placeholder: "Tag name", button: "Add") {
                store.batch("Tags") { for item in items { store.setTags(item.id, item.tags + [value]) } }
                done()
            }
        })
        return SearchListPopover(placeholder: "Tags", rows: rows, footer: ("Clear", {
            store.batch("Tags") { ids.forEach { store.setTags($0, []) } }
            done()
        }))
    }
}


extension SearchListPopover {
    /// Things' Quick Find: lists, areas, projects, tags and to-dos as you type.
    static func quickFind(onContinue: @escaping (String) -> Void) -> SearchListPopover {
        let controller = SearchListPopover(placeholder: "Quick Find", rows: [])
        controller.width = 420
        controller.rowLimit = 12
        controller.provider = { query in
            let store = TaskStore.shared
            let q = query.lowercased()
            guard !q.isEmpty else { return [] }
            var rows: [Row] = []
            for list in BuiltinList.allCases where list.title.lowercased().hasPrefix(q) {
                rows.append(Row(title: list.title, symbol: list.symbol, color: Theme.listColor(list)) {
                    AppState.shared.selection = .builtin(list)
                })
            }
            for area in store.areas where area.title.lowercased().contains(q) {
                rows.append(Row(title: area.title, symbol: "shippingbox", color: Theme.success) { AppState.shared.selection = .area(area.id) })
            }
            for project in store.openProjects where project.title.lowercased().contains(q) {
                rows.append(Row(title: project.title, symbol: "circle", color: Theme.accent,
                                subtitle: project.areaID.flatMap { store.area($0)?.title }) { AppState.shared.selection = .project(project.id) })
            }
            for idea in store.ideas where idea.title.lowercased().contains(q) {
                rows.append(Row(title: idea.title, symbol: "lightbulb", color: Theme.idea, subtitle: idea.ideaStage.title) {
                    NotificationCenter.default.post(name: .openTask, object: idea.id)
                })
            }
            for tag in store.allTags where tag.lowercased().contains(q) {
                rows.append(Row(title: tag, symbol: "tag", color: Theme.secondary) { AppState.shared.selection = .tag(tag) })
            }
            for task in store.search(query).filter(\.isTodo).prefix(8) {
                let parent = task.projectID.flatMap { store.task($0)?.title } ?? task.areaID.flatMap { store.area($0)?.title }
                rows.append(Row(title: task.title, symbol: task.isCompleted ? "checkmark.square" : "square", color: Theme.secondary,
                                subtitle: parent) { NotificationCenter.default.post(name: .openTask, object: task.id) })
            }
            rows.append(Row(title: "Continue Search", symbol: "magnifyingglass", color: Theme.secondary, separatorBefore: true) {
                onContinue(query)
            })
            return rows
        }
        return controller
    }
}
