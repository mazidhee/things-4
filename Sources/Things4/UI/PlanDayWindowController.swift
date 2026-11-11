import AppKit

/// "Plan My Day": talk or type everything on your mind, review the sorted list, add it to Today.
final class PlanDayWindowController: NSWindowController, NSTextViewDelegate {
    static let shared = PlanDayWindowController()

    private let heading = NSTextField.label("Plan My Day", font: Fonts.semibold(16), color: Theme.text)
    private let hint = NSTextField.label("Say or type everything you want to get done, in any order. Mention what matters most.",
                                         font: Fonts.regular(12.5), color: Theme.secondary)
    private let textView = PlaceholderTextView()
    private let textScroll = NSScrollView()
    private let sortButton = NSButton(title: "Sort It Out", target: nil, action: nil)
    private let statusLabel = NSTextField.label("", font: Fonts.regular(12), color: Theme.secondary)
    private let spinner = NSProgressIndicator()
    private let listScroll = NSScrollView()
    private let listView = FlippedView()
    private let emptyLabel = NSTextField.wrappingLabel("", font: Fonts.regular(13), color: Theme.tertiary)
    private let clearToggle = NSButton(checkboxWithTitle: "Move everything else out of Today", target: nil, action: nil)
    private let applyButton = NSButton(title: "Add to Today", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var items: [PlanItem] = []
    /// The text the current list was made from; editing it makes ⌘↩ sort again.
    private var sortedText: String?
    private var working = false

    private static let size = NSSize(width: 640, height: 600)

    private convenience init() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Plan My Day"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.cardElevated
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        self.init(window: panel)
        buildUI()
    }

    func show(text: String? = nil) {
        guard let window else { return }
        if let text {
            textView.string = text
            textView.needsDisplay = true
        }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        refresh()
    }

    private func buildUI() {
        guard let window else { return }
        let root = FlippedView(fill: Theme.cardElevated)
        window.contentView = root
        let width = Self.size.width, pad: CGFloat = 26

        heading.frame = NSRect(x: pad, y: 34, width: 300, height: 22)
        hint.frame = NSRect(x: pad, y: 60, width: width - pad * 2, height: 18)
        root.addSubview(heading)
        root.addSubview(hint)

        textView.font = Fonts.regular(14.5)
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.accent
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholderString = "I need to get the staging package done today, that's the main thing. Then…"
        textView.delegate = self
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        let textBox = PlanBox(frame: NSRect(x: pad, y: 90, width: width - pad * 2, height: 150))
        textScroll.frame = textBox.bounds.insetBy(dx: 1, dy: 1)
        textView.frame = NSRect(origin: .zero, size: textScroll.contentSize)
        textBox.addSubview(textScroll)
        root.addSubview(textBox)

        sortButton.bezelStyle = .rounded
        sortButton.target = self
        sortButton.action = #selector(sortTapped)
        sortButton.frame = NSRect(x: pad - 5, y: 250, width: 118, height: 30)
        root.addSubview(sortButton)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: pad + 122, y: 257, width: 16, height: 16)
        root.addSubview(spinner)
        statusLabel.frame = NSRect(x: pad + 122, y: 257, width: width - pad * 2 - 130, height: 16)
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        listScroll.documentView = listView
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.frame = NSRect(x: pad, y: 294, width: width - pad * 2, height: 236)
        root.addSubview(listScroll)
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: pad + 60, y: 370, width: width - pad * 2 - 120, height: 60)
        root.addSubview(emptyLabel)

        clearToggle.font = Fonts.regular(12.5)
        clearToggle.frame = NSRect(x: pad - 2, y: 551, width: 280, height: 20)
        root.addSubview(clearToggle)
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applyTapped)
        applyButton.frame = NSRect(x: width - pad - 124, y: 545, width: 130, height: 30)
        root.addSubview(applyButton)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: width - pad - 124 - 90, y: 545, width: 90, height: 30)
        root.addSubview(cancelButton)
    }

    // MARK: - State

    private var currentText: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// True when the list on screen still matches what is written.
    private var listIsCurrent: Bool { sortedText != nil && sortedText == currentText && !items.isEmpty }

    private func refresh() {
        let chosen = items.filter(\.include).count
        applyButton.isEnabled = !working && chosen > 0
        applyButton.title = chosen > 0 ? "Add \(chosen) to Today" : "Add to Today"
        sortButton.isEnabled = !working && !currentText.isEmpty
        // ⌘↩ does the next sensible thing: sort first, then add.
        sortButton.keyEquivalent = listIsCurrent ? "" : "\r"
        sortButton.keyEquivalentModifierMask = listIsCurrent ? [] : .command
        applyButton.keyEquivalent = listIsCurrent ? "\r" : ""
        applyButton.keyEquivalentModifierMask = listIsCurrent ? .command : []
        clearToggle.isHidden = items.isEmpty
        emptyLabel.isHidden = !items.isEmpty || working
        emptyLabel.stringValue = sortedText == nil
            ? "Your list appears here, most important first. Press ⌘↩ when you have finished talking."
            : "Nothing in that sounded like a to-do. Try naming the things you want to get done."
        rebuildRows()
    }

    private func rebuildRows() {
        listView.removeAllSubviews()
        let width = listScroll.contentSize.width
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            let row = PlanRowView(item: item, number: index + 1)
            row.frame = NSRect(x: 0, y: y, width: width, height: 40)
            row.onChange = { [weak self] updated in
                guard let self, index < self.items.count else { return }
                self.items[index] = updated
                DispatchQueue.main.async { self.refresh() }
            }
            listView.addSubview(row)
            y += 40
        }
        listView.frame = NSRect(x: 0, y: 0, width: width, height: max(y, listScroll.contentSize.height))
    }

    func textDidChange(_ notification: Notification) {
        if sortedText != nil, !listIsCurrent { statusLabel.stringValue = "Edited. Press ⌘↩ to sort again." }
        refresh()
    }

    // MARK: - Actions

    @objc fileprivate func sortTapped() {
        let text = currentText
        guard !text.isEmpty, !working else { return }
        working = true
        statusLabel.stringValue = ""
        spinner.startAnimation(nil)
        refresh()
        Task { @MainActor in
            let result = await DayPlanner.plan(text)
            self.working = false
            self.spinner.stopAnimation(nil)
            self.items = result.items
            self.sortedText = text
            let existing = result.items.filter { $0.taskID != nil }.count
            var status = result.items.isEmpty ? "" : "\(result.items.count) to-do\(result.items.count == 1 ? "" : "s"), \(existing) already in Things."
            if let problem = result.problem { status = problem }
            else if !result.usedAI && !result.items.isEmpty { status += " Sorted on this Mac." }
            self.statusLabel.stringValue = status
            self.refresh()
        }
    }

    @objc private func applyTapped() {
        guard !working, items.contains(where: \.include) else { return }
        window?.makeFirstResponder(nil)
        DayPlanner.apply(items, clearRest: clearToggle.state == .on)
        items = []
        sortedText = nil
        textView.string = ""
        statusLabel.stringValue = ""
        clearToggle.state = .off
        window?.orderOut(nil)
        (MainWindowController.active ?? .shared).state.selection = .builtin(.today)
        (MainWindowController.active ?? .shared).window?.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelTapped() {
        window?.orderOut(nil)
    }
}

/// The rounded well around the dictation field.
private final class PlanBox: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        Theme.window.setFill()
        path.fill()
        Theme.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// One planned to-do: include box, priority, editable title, where it comes from, when.
final class PlanRowView: FlippedView, NSTextFieldDelegate {
    var onChange: ((PlanItem) -> Void)?
    private var item: PlanItem
    private let include = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let priorityButton = NSButton()
    private let titleField = NSTextField.inlineField(placeholder: "To-do", font: Fonts.regular(14))
    private let detail = NSTextField.label("", font: Fonts.regular(11.5), color: Theme.secondary)
    private let whenButton = FlatButton(title: "", symbol: nil, color: Theme.secondary, fontSize: 12)

    init(item: PlanItem, number: Int) {
        self.item = item
        super.init(frame: .zero)
        include.state = item.include ? .on : .off
        include.target = self
        include.action = #selector(includeChanged)
        addSubview(include)

        priorityButton.isBordered = false
        priorityButton.image = WorkflowIcons.priorityImage(item.priority, size: 16)
        priorityButton.toolTip = item.priority.title
        priorityButton.target = self
        priorityButton.action = #selector(priorityTapped)
        addSubview(priorityButton)

        titleField.stringValue = item.title
        titleField.isEditable = item.taskID == nil
        titleField.isSelectable = item.taskID == nil
        titleField.textColor = item.include ? Theme.text : Theme.tertiary
        titleField.lineBreakMode = .byTruncatingTail
        titleField.delegate = self
        addSubview(titleField)

        let store = TaskStore.shared
        if let existing = item.taskID.flatMap({ store.task($0) }) {
            detail.stringValue = existing.projectID.flatMap { store.task($0)?.title } ?? existing.areaID.flatMap { store.area($0)?.title } ?? "In Things"
        } else {
            detail.stringValue = "New" + (item.projectID.flatMap { store.task($0)?.title }.map { " · " + $0 } ?? "")
            detail.textColor = Theme.accent
        }
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        addSubview(detail)

        whenButton.title = item.when.title
        whenButton.target = self
        whenButton.action = #selector(whenTapped)
        addSubview(whenButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = bounds.width
        include.frame = NSRect(x: 2, y: 10, width: 20, height: 20)
        priorityButton.frame = NSRect(x: 28, y: 10, width: 22, height: 20)
        let whenWidth: CGFloat = 96
        whenButton.frame = NSRect(x: width - whenWidth, y: 9, width: whenWidth, height: 22)
        let detailWidth = min(170, ceil(detail.attributedStringValue.size().width) + 8)
        detail.frame = NSRect(x: width - whenWidth - detailWidth - 8, y: 12, width: detailWidth, height: 16)
        titleField.frame = NSRect(x: 58, y: 10, width: max(80, detail.frame.minX - 66), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func includeChanged() {
        item.include = include.state == .on
        onChange?(item)
    }

    @objc private func priorityTapped() {
        let menu = NSMenu()
        for priority in Priority.allCases.reversed() {
            let entry = ClosureMenuItem(priority.title, checked: item.priority == priority) { [weak self] in
                guard let self else { return }
                self.item.priority = priority
                self.onChange?(self.item)
            }
            entry.image = WorkflowIcons.priorityImage(priority)
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: priorityButton.bounds.height + 4), in: priorityButton)
    }

    @objc private func whenTapped() {
        let menu = NSMenu()
        for when in [PlanItem.When.today, .evening, .tomorrow, .later] {
            menu.addItem(ClosureMenuItem(when.title, checked: item.when == when) { [weak self] in
                guard let self else { return }
                self.item.when = when
                self.onChange?(self.item)
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: whenButton.bounds.height + 4), in: whenButton)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != item.title else { return }
        item.title = title
        onChange?(item)
    }
}

// MARK: - Snapshot hooks (used by --snapshot-plan only)

extension PlanDayWindowController {
    func debugSort() { sortTapped() }

    func debugSnapshot(_ path: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
