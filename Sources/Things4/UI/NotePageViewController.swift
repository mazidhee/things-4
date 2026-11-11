import AppKit

extension Notification.Name {
    static let openNotePage = Notification.Name("Things4.openNotePage")
    static let closeNotePage = Notification.Name("Things4.closeNotePage")
}

/// A to-do or project opened as a document, in the spirit of Notion / Bear / Craft:
/// breadcrumb bar, large wrapping title, a property list, and a roomy Markdown body.
final class NotePageViewController: NSViewController, NSTextViewDelegate {
    let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private(set) var taskID: String?
    private var task: TaskItem?

    // Top bar
    private let topBar = FillView(fill: Theme.window)
    private let backButton = FlatButton(title: "", symbol: "chevron.left", color: Theme.secondary, fontSize: 13)
    private let breadcrumb = NSTextField.label("", font: Fonts.medium(12.5), color: Theme.secondary)
    private let previewButton = FlatButton(title: "Preview", symbol: nil, color: Theme.secondary, fontSize: 12.5)
    private let moreButton = IconButton(symbol: "ellipsis", size: 14, color: Theme.secondary, tooltip: "More")

    // Document
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let checkbox = CheckboxView()
    private let ring = ProgressRing()
    private let ideaIcon = NSImageView()
    private var promoteBar: IdeaPromoteBar?
    private let titleView = TitleTextView()
    private var propertyRows: [PropertyRow] = []
    private let divider = FillView(fill: Theme.separator)
    private let body = MarkdownTextView()
    private let preview = NSTextView()
    private let footer = NSTextField.label("", font: Fonts.regular(11.5), color: Theme.tertiary)
    private var previewing = false
    private var saveTimer: Timer?

    private let columnMax: CGFloat = 720

    override func loadView() {
        let root = FillView(fill: Theme.window)
        view = root

        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = "Back (Esc)"
        previewButton.target = self
        previewButton.action = #selector(togglePreview)
        moreButton.target = self
        moreButton.action = #selector(showMore)
        breadcrumb.lineBreakMode = .byTruncatingMiddle
        [backButton, breadcrumb, previewButton, moreButton].forEach(topBar.addSubview)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        root.addSubview(scroll)
        root.addSubview(topBar)

        checkbox.isSquare = true
        checkbox.onToggle = { [weak self] alternate in
            guard let self, let task = self.task else { return }
            if alternate && task.isOpen { TaskStore.shared.cancel(task.id) } else { TaskStore.shared.toggleCompletion(task.id) }
        }
        ring.color = Theme.accent
        titleView.onCommit = { [weak self] in
            self?.save()
            if let body = self?.body { self?.view.window?.makeFirstResponder(body) }
        }
        titleView.onChange = { [weak self] in self?.layoutDocument(); self?.scheduleSave() }
        titleView.onEscape = { [weak self] in self?.goBack() }

        body.configure(baseSize: 16)
        body.relaxed = true
        body.placeholderString = "Start writing…"
        body.textContainerInset = NSSize(width: 0, height: 4)
        body.textContainer?.lineFragmentPadding = 0
        body.delegate = self
        body.onChange = { [weak self] in self?.layoutDocument(); self?.scheduleSave() }

        preview.isEditable = false
        preview.isSelectable = true
        preview.drawsBackground = false
        preview.textContainer?.lineFragmentPadding = 0
        preview.isHidden = true

        footer.alignment = .right
        ideaIcon.image = NSImage.symbol("lightbulb.fill", size: 17, weight: .medium, color: Theme.idea)
        ideaIcon.imageScaling = .scaleProportionallyUpOrDown
        [checkbox, ring, ideaIcon, titleView, divider, body, preview].forEach(document.addSubview)
        root.addSubview(footer)

        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .storeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Layout

    private var column: (x: CGFloat, width: CGFloat) {
        let width = scroll.contentSize.width
        let w = min(columnMax, max(320, width - 160))
        return (floor((width - w) / 2), w)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        topBar.frame = NSRect(x: 0, y: bounds.height - 44, width: bounds.width, height: 44)
        backButton.frame = NSRect(x: 16, y: 11, width: 24, height: 22)
        breadcrumb.frame = NSRect(x: 44, y: 13, width: max(100, bounds.width - 240), height: 18)
        moreButton.frame = NSRect(x: bounds.width - 40, y: 11, width: 26, height: 22)
        previewButton.frame = NSRect(x: bounds.width - 112, y: 11, width: 68, height: 22)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 44)
        footer.frame = NSRect(x: bounds.width - 300, y: 10, width: 284, height: 16)
        layoutDocument()
    }

    private func layoutDocument() {
        let (x, width) = column
        var y: CGFloat = 36
        let titleIndent: CGFloat = 34
        titleView.frame.size.width = width - titleIndent
        let titleHeight = titleView.fittingHeight(width: width - titleIndent)
        checkbox.frame = NSRect(x: x, y: y + 13, width: 18, height: 18)
        ring.frame = NSRect(x: x - 2, y: y + 10, width: 24, height: 24)
        ideaIcon.frame = NSRect(x: x - 1, y: y + 11, width: 20, height: 22)
        titleView.frame = NSRect(x: x + titleIndent, y: y, width: width - titleIndent, height: titleHeight)
        y += titleHeight + 18

        for row in propertyRows {
            row.frame = NSRect(x: x - 6, y: y, width: width + 12, height: 32)
            y += 32
        }
        if let promoteBar {
            y += 16
            promoteBar.frame = NSRect(x: x, y: y, width: width, height: IdeaPromoteBar.height)
            y += IdeaPromoteBar.height + 6
        }
        y += 14
        divider.frame = NSRect(x: x, y: y, width: width, height: 1)
        y += 22

        let textHeight: CGFloat
        if previewing {
            textHeight = max(200, (preview.layoutManager?.usedRect(for: preview.textContainer!).height ?? 0) + 20)
            preview.frame = NSRect(x: x, y: y, width: width, height: textHeight)
            preview.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        } else {
            textHeight = max(scroll.contentSize.height - y - 60, body.contentHeight(for: width) + 40)
            body.frame = NSRect(x: x, y: y, width: width, height: textHeight)
        }
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, y + textHeight + 80))
    }

    // MARK: - Content

    func show(taskID: String, returnTo selection: Selection) {
        guard let task = TaskStore.shared.task(taskID) else { return }
        if let current = self.taskID, current != taskID { save() }
        self.taskID = taskID
        self.task = task
        titleView.string = task.title
        body.setMarkdown(task.notes)
        setPreview(false)
        refresh()
        scroll.contentView.scroll(to: .zero)
    }

    /// Called once the page is on screen.
    func focusInitial() {
        view.layoutSubtreeIfNeeded()
        guard let task else { return }
        if task.title == "New To-Do" || task.title == "New Idea" || task.title.isEmpty {
            view.window?.makeFirstResponder(titleView)
            titleView.selectAll(nil)
        } else {
            view.window?.makeFirstResponder(body)
            body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        }
    }

    private func refresh() {
        guard let task else { return }
        let store = TaskStore.shared
        checkbox.isHidden = task.isProject || task.isIdea
        ring.isHidden = !task.isProject
        ideaIcon.isHidden = !task.isIdea
        checkbox.isChecked = task.isCompleted
        checkbox.isCanceled = task.isCanceled
        if task.isProject {
            let p = store.projectProgress(task.id)
            ring.progress = p.total == 0 ? 0 : Double(p.done) / Double(p.total)
        }

        var crumbs: [String] = []
        if let areaID = task.areaID, let area = store.area(areaID) { crumbs.append(area.title) }
        if let projectID = task.projectID, let project = store.task(projectID) { crumbs.append(project.title) }
        if task.isIdea { crumbs = ["Ideas"] }
        if crumbs.isEmpty { crumbs.append(task.isProject ? "Projects" : (task.bucket == .inbox ? "Inbox" : "To-Dos")) }
        crumbs.append(task.title.isEmpty ? "Untitled" : task.title)
        breadcrumb.stringValue = crumbs.joined(separator: "  /  ")

        propertyRows.forEach { $0.removeFromSuperview() }
        propertyRows = buildProperties(for: task)
        propertyRows.forEach(document.addSubview)
        promoteBar?.removeFromSuperview()
        promoteBar = nil
        if task.isIdea && task.isOpen {
            let bar = IdeaPromoteBar(ideaID: task.id)
            document.addSubview(bar)
            promoteBar = bar
        }

        let words = body.string.split { $0.isWhitespace || $0.isNewline }.count
        let edited = task.modifiedAt.isToday
            ? DateFormatter.localizedString(from: task.modifiedAt, dateStyle: .none, timeStyle: .short)
            : DateFormatter.localizedString(from: task.modifiedAt, dateStyle: .medium, timeStyle: .none)
        footer.stringValue = "\(words) word\(words == 1 ? "" : "s")  ·  Edited \(edited)"
        view.needsLayout = true
    }

    private func buildProperties(for task: TaskItem) -> [PropertyRow] {
        let store = TaskStore.shared
        var rows: [PropertyRow] = []
        let timeFormatter = DateFormatter(); timeFormatter.timeStyle = .short
        if task.isIdea { return ideaProperties(for: task) }
        if !task.isProject || true {
            let when: (String, NSColor)? = {
                if task.isEvening { return ("This Evening", Theme.text) }
                if let start = task.startDate { return (start < Date().startOfDay.addingDays(1) ? "Today" : Format.relativeDay(start) + ", " + start.monthDayString, Theme.text) }
                if task.bucket == .someday { return ("Someday", Theme.text) }
                if task.bucket == .anytime { return ("Anytime", Theme.text) }
                return nil
            }()
            rows.append(PropertyRow(symbol: "calendar", label: "When", value: when?.0, valueColor: when?.1 ?? Theme.text) { [weak self] row in
                self?.pickWhen(from: row)
            })
        }
        if task.isTodo {
            rows.append(PropertyRow(symbol: "bell", label: "Reminder", value: task.reminder.map { Format.relativeDay($0) + " at " + timeFormatter.string(from: $0) },
                                    valueColor: Theme.text) { [weak self] row in self?.pickWhen(from: row) })
        }
        rows.append(PropertyRow(symbol: "flag", label: "Deadline", value: task.deadline.map { Format.relativeDay($0) + ", " + $0.monthDayString },
                                valueColor: task.deadline.map { $0 <= Date().startOfDay ? Theme.deadline : Theme.text } ?? Theme.text) { [weak self] row in
            self?.pickDeadline(from: row)
        })
        let list: String? = task.projectID.flatMap { store.task($0)?.title } ?? task.areaID.flatMap { store.area($0)?.title }
            ?? (task.bucket == .inbox ? "Inbox" : nil)
        rows.append(PropertyRow(symbol: task.projectID != nil ? "circle" : "shippingbox", label: task.isProject ? "Area" : "List",
                                value: list, valueColor: Theme.text) { [weak self] row in
            guard let self, let id = self.taskID else { return }
            SearchListPopover.show(.move(ids: [id]) { [weak self] in self?.refresh() }, relativeTo: row.valueRect, of: row)
        })
        rows.append(PropertyRow(symbol: "tag", label: "Tags", value: task.tags.isEmpty ? nil : task.tags.joined(separator: ", "),
                                valueColor: Theme.text) { [weak self] row in
            guard let self, let id = self.taskID else { return }
            SearchListPopover.show(.tags(ids: [id]) { [weak self] in self?.refresh() }, relativeTo: row.valueRect, of: row)
        })
        if task.isTodo {
            rows.append(PropertyRow(symbol: "repeat", label: "Repeat", value: task.repeatRule?.summary, valueColor: Theme.text) { [weak self] _ in
                guard let id = self?.taskID else { return }
                TaskMenus.showRepeat(for: [id]) { self?.refresh() }
            })
        }
        return rows
    }

    /// An idea has no dates: just how far along it is, where it would live, and tags.
    private func ideaProperties(for idea: TaskItem) -> [PropertyRow] {
        let store = TaskStore.shared
        var rows: [PropertyRow] = []
        rows.append(PropertyRow(symbol: "circle.dashed", label: "Stage", value: idea.ideaStage.title,
                                valueColor: Theme.ideaStageColor(idea.ideaStage)) { row in
            IdeaActions.stageMenu(for: idea.id).popUp(positioning: nil, at: NSPoint(x: row.valueRect.minX, y: row.bounds.height), in: row)
        })
        rows.append(PropertyRow(symbol: "things.area.plain", label: "Area", value: idea.areaID.flatMap { store.area($0)?.title },
                                valueColor: Theme.text) { row in
            IdeaActions.areaMenu(for: idea.id).popUp(positioning: nil, at: NSPoint(x: row.valueRect.minX, y: row.bounds.height), in: row)
        })
        rows.append(PropertyRow(symbol: "tag", label: "Tags", value: idea.tags.isEmpty ? nil : idea.tags.joined(separator: ", "),
                                valueColor: Theme.text) { [weak self] row in
            guard let self, let id = self.taskID else { return }
            SearchListPopover.show(.tags(ids: [id]) { [weak self] in self?.refresh() }, relativeTo: row.valueRect, of: row)
        })
        return rows
    }

    private func pickWhen(from row: PropertyRow) {
        guard let task else { return }
        WhenPicker.show(mode: .when, current: task.startDate, reminder: task.reminder, relativeTo: row.valueRect, of: row) { [weak self] choice in
            choice.applyWhen(to: [task.id])
            self?.refresh()
        }
    }

    private func pickDeadline(from row: PropertyRow) {
        guard let task else { return }
        WhenPicker.show(mode: .deadline, current: task.deadline, relativeTo: row.valueRect, of: row) { [weak self] choice in
            choice.applyDeadline(to: [task.id])
            self?.refresh()
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.save() }
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let task else { return }
        TaskStore.shared.batch("Edit Note") {
            if body.string != task.notes { TaskStore.shared.setNotes(task.id, body.string) }
            let title = titleView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, title != task.title { TaskStore.shared.setTitle(task.id, title) }
        }
        if let fresh = TaskStore.shared.task(task.id) { self.task = fresh }
    }

    @objc private func storeChanged() {
        guard let taskID, !view.isHidden else { return }
        guard let fresh = TaskStore.shared.task(taskID), fresh.status != .trashed else {
            goBack()
            return
        }
        let responder = view.window?.firstResponder
        task = fresh
        if responder !== body, saveTimer == nil, body.string != fresh.notes { body.setMarkdown(fresh.notes) }
        if responder !== titleView, titleView.string != fresh.title { titleView.string = fresh.title }
        refresh()
    }

    // MARK: - Actions

    @objc private func togglePreview() { setPreview(!previewing) }

    private func setPreview(_ on: Bool) {
        previewing = on
        if on {
            save()
            var style = Markdown.render(body.string, baseSize: 16)
            if body.string.isEmpty { style = NSAttributedString(string: "Nothing written yet.", attributes: [.font: Fonts.regular(16), .foregroundColor: Theme.tertiary]) }
            preview.textStorage?.setAttributedString(style)
        }
        body.isHidden = on
        preview.isHidden = !on
        previewButton.title = on ? "Edit" : "Preview"
        layoutDocument()
        view.window?.makeFirstResponder(on ? preview : body)
    }

    @objc private func showMore() {
        guard let id = taskID else { return }
        let menu = TaskStore.shared.task(id)?.isIdea == true
            ? IdeaActions.contextMenu(for: id)
            : TaskMenus.context(for: [id], selection: state.selection) { [weak self] in self?.refresh() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
    }

    @objc func goBack() {
        save()
        NotificationCenter.default.post(name: .closeNotePage, object: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { goBack(); return }
        super.keyDown(with: event)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { goBack(); return true }
        return false
    }

    func textDidEndEditing(_ notification: Notification) { save() }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { NSWorkspace.shared.open(url); return true }
        return false
    }
}

/// The big wrapping document title. Return moves into the body; no select-all on focus.
final class TitleTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onChange: (() -> Void)?
    var onEscape: (() -> Void)?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        font = .systemFont(ofSize: 34 * Fonts.scale, weight: .bold)
        textColor = Theme.text
        insertionPointColor = Theme.text
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isVerticallyResizable = true
        typingAttributes = [.font: NSFont.systemFont(ofSize: 34 * Fonts.scale, weight: .bold), .foregroundColor: Theme.text]
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        ("Untitled" as NSString).draw(at: .zero, withAttributes: [.font: NSFont.systemFont(ofSize: 34 * Fonts.scale, weight: .bold),
                                                                 .foregroundColor: Theme.placeholder])
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 44 }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(44, ceil(layoutManager.usedRect(for: textContainer).height) + 4)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onChange?()
    }

    override func insertNewline(_ sender: Any?) { onCommit?() }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// One Notion-style property: icon + grey label on the left, value (or "Empty") on the right.
final class PropertyRow: NSView {
    private let symbol: String
    private let label: String
    private let value: String?
    private let valueColor: NSColor
    private let action: (PropertyRow) -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private let labelWidth: CGFloat = 150

    var valueRect: NSRect { NSRect(x: labelWidth, y: 0, width: 200, height: bounds.height) }
    override var isFlipped: Bool { true }

    init(symbol: String, label: String, value: String?, valueColor: NSColor, action: @escaping (PropertyRow) -> Void) {
        self.symbol = symbol
        self.label = label
        self.value = value
        self.valueColor = valueColor
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { action(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.rowHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let mid = bounds.height / 2
        NSImage.symbol(symbol, size: 13, weight: .regular, color: Theme.tertiary)?.draw(in: NSRect(x: 8, y: mid - 8, width: 16, height: 16))
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: Fonts.regular(14), .foregroundColor: Theme.secondary]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        (label as NSString).draw(at: NSPoint(x: 34, y: mid - labelSize.height / 2), withAttributes: labelAttrs)
        let text = value ?? "Empty"
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: Fonts.regular(14),
                                                        .foregroundColor: value == nil ? Theme.placeholder : valueColor]
        let valueSize = (text as NSString).size(withAttributes: valueAttrs)
        (text as NSString).draw(with: NSRect(x: labelWidth, y: mid - valueSize.height / 2, width: bounds.width - labelWidth - 8, height: valueSize.height + 2),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: valueAttrs)
    }
}
