import AppKit

enum EditorFocus {
    case title, notes, tags, checklist
}

final class MenuButton: NSButton {
    var menuProvider: (() -> NSMenu)?

    init(title: String, symbol: String? = nil, color: NSColor = Theme.secondary) {
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.font = Fonts.regular(12)
        self.contentTintColor = color
        self.imagePosition = .imageLeading
        self.alignment = .left
        self.lineBreakMode = .byTruncatingTail
        if let symbol {
            self.image = NSImage.symbol(symbol, size: 12, weight: .regular, color: color)
        }
        self.setButtonType(.momentaryChange)
        self.refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

/// The opened to-do, Things style: a raised card with the title, Markdown notes,
/// an optional checklist, chips for the values that are set, and four icons
/// (When, Tags, Checklist, Deadline) at the bottom right.
final class TaskEditorView: FlippedView, NSTextFieldDelegate, NSTextViewDelegate {
    private(set) var task: TaskItem

    var onClose: (() -> Void)?
    var onReload: (() -> Void)?
    var onAIEnhance: ((TaskItem) -> Void)?
    var onHeightChange: (() -> Void)?

    private let checkbox = CheckboxView()
    private let titleField = NSTextField()
    private let notesTextView = MarkdownTextView()
    private let tagsField = NSTextField()
    private let addChecklistField = NSTextField()
    private let addChecklistHost = ChecklistAddRowBackground()
    private let expandButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 10, color: Theme.tertiary, tooltip: "Open as page (⌥⌘O)")
    private let restoreButton = FlatButton(title: "Put Back", symbol: "arrow.uturn.backward", color: Theme.accent)

    private let whenIcon = IconButton(symbol: "calendar", size: 14, color: Theme.secondary, tooltip: "When (⌘S)")
    private let tagIcon = IconButton(symbol: "tag", size: 14, color: Theme.secondary, tooltip: "Tags (⇧⌘T)")
    private let checklistIcon = IconButton(symbol: "list.bullet", size: 14, color: Theme.secondary, tooltip: "Checklist (⇧⌘C)")
    private let deadlineIcon = IconButton(symbol: "flag", size: 14, color: Theme.secondary, tooltip: "Deadline (⇧⌘D)")
    private let remindIcon = IconButton(symbol: "bell", size: 14, color: Theme.secondary, tooltip: "Remind Me (⌥⌘R)")
    private let aiIcon = IconButton(symbol: "sparkles", size: 13, color: Theme.accent, tooltip: "Enhance with AI")

    private let breadcrumb = FlatButton(title: "", symbol: nil, color: Theme.secondary, fontSize: 12.5)
    private var whenChip: ChipButton?
    private var deadlineChip: ChipButton?
    private var timeChip: ChipButton?
    /// Status, priority and estimate share one row.
    private var flowChips: [ChipButton] = []
    private var repeatChip: ChipButton?
    private var checklistRows: [NSView] = []
    private var checklistFields: [NSTextField] = []
    private var showsTags = false
    private var tagTokens: [TagToken] = []

    private func rebuildTagTokens() {
        tagTokens.forEach { $0.removeFromSuperview() }
        tagTokens = task.tags.map { tag in
            let token = TagToken(tag: tag)
            token.onRemove = { [weak self] name in
                guard let self else { return }
                TaskStore.shared.setTags(self.task.id, self.task.tags.filter { $0 != name })
                self.onReload?()
            }
            addSubview(token)
            return token
        }
        needsLayout = true
    }

    /// Adds whatever is typed in the tag field as tags (comma-separated allowed).
    private func commitTagInput() {
        let names = tagsField.stringValue.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        tagsField.stringValue = ""
        guard !names.isEmpty else { return }
        var tags = task.tags
        for name in names where !tags.contains(name) { tags.append(name) }
        TaskStore.shared.setTags(task.id, tags)
        if let fresh = TaskStore.shared.task(task.id) { task = fresh }
        rebuildTagTokens()
        onReload?()
    }
    private var showsChecklist = false
    private var notesSaveTimer: Timer?
    private var lastHeight: CGFloat = 0

    private static let textX: CGFloat = 40
    private static let notesFont: CGFloat = 14

    init(task: TaskItem) {
        self.task = task
        super.init(frame: .zero)

        checkbox.isSquare = true
        checkbox.isChecked = task.isCompleted
        checkbox.isCanceled = task.isCanceled
        checkbox.onToggle = { [weak self] alternate in
            guard let self else { return }
            if alternate && self.task.isOpen { TaskStore.shared.cancel(self.task.id) } else { TaskStore.shared.toggleCompletion(self.task.id) }
            self.onClose?()
        }
        addSubview(checkbox)

        titleField.stringValue = task.title
        titleField.font = Fonts.regular(14.5)
        titleField.textColor = Theme.text
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.placeholderString = "New To-Do"
        titleField.delegate = self
        titleField.cell?.isScrollable = true
        addSubview(titleField)

        notesTextView.configure(baseSize: Self.notesFont)
        notesTextView.textContainerInset = NSSize(width: 0, height: 2)
        notesTextView.textContainer?.lineFragmentPadding = 0
        notesTextView.placeholderString = "Notes"
        notesTextView.delegate = self
        notesTextView.setMarkdown(task.notes)
        notesTextView.onChange = { [weak self] in self?.notesChanged() }
        addSubview(notesTextView)

        tagsField.stringValue = ""
        tagsField.font = Fonts.regular(13)
        tagsField.textColor = Theme.text
        tagsField.isBordered = false
        tagsField.drawsBackground = false
        tagsField.focusRingType = .none
        tagsField.placeholderString = ""
        tagsField.delegate = self
        addSubview(tagsField)
        showsTags = !task.tags.isEmpty
        rebuildTagTokens()

        addChecklistField.font = Fonts.regular(13)
        addChecklistField.textColor = Theme.text
        addChecklistField.isBordered = false
        addChecklistField.drawsBackground = false
        addChecklistField.focusRingType = .none
        addChecklistField.placeholderString = ""
        addChecklistField.font = Fonts.regular(14)
        addChecklistField.delegate = self
        addChecklistHost.field = addChecklistField
        addSubview(addChecklistHost)
        addSubview(addChecklistField)
        showsChecklist = !task.checklist.isEmpty

        expandButton.target = self
        expandButton.action = #selector(expandTapped)
        addSubview(expandButton)

        for (button, action) in [(whenIcon, #selector(whenTapped)), (tagIcon, #selector(tagsTapped)),
                                 (checklistIcon, #selector(checklistTapped)), (deadlineIcon, #selector(deadlineTapped)),
                                 (remindIcon, #selector(remindTapped)), (aiIcon, #selector(aiTapped))] {
            button.target = self
            button.action = action
            addSubview(button)
        }

        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        addSubview(restoreButton)

        breadcrumb.target = self
        breadcrumb.action = #selector(breadcrumbTapped)
        breadcrumb.imagePosition = .imageLeading
        addSubview(breadcrumb)

        refreshControls()
        rebuildChecklist()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let breadcrumbHeight: CGFloat = 30

    override func draw(_ dirtyRect: NSRect) {
        var rect = bounds.insetBy(dx: -10, dy: 0)
        rect.size.height -= Self.breadcrumbHeight
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        Theme.cardElevated.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Sizing

    private func notesHeight(width: CGFloat) -> CGFloat {
        max(20, notesTextView.contentHeight(for: width - Self.textX - 16))
    }

    private func bodyHeight(width: CGFloat) -> CGFloat {
        var height: CGFloat = 14 + 22 + 6 + notesHeight(width: width) + 10
        if showsChecklist { height += CGFloat(task.checklist.count + 1) * ChecklistRowView.height + 6 }
        if showsTags { height += 32 }
        height += CGFloat(max(1, valueRowCount)) * 28 + 12
        return height + Self.breadcrumbHeight
    }

    private var valueRowCount: Int { [whenChip, deadlineChip, repeatChip, timeChip].compactMap { $0 }.count + (flowChips.isEmpty ? 0 : 1) }

    static func height(for task: TaskItem, width: CGFloat) -> CGFloat {
        let probe = TaskEditorView(task: task)
        return probe.bodyHeight(width: width)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let height = bodyHeight(width: width)
        lastHeight = height
        return height
    }

    // MARK: - State

    private func refreshControls() {
        whenChip?.removeFromSuperview(); whenChip = nil
        deadlineChip?.removeFromSuperview(); deadlineChip = nil
        repeatChip?.removeFromSuperview(); repeatChip = nil
        timeChip?.removeFromSuperview(); timeChip = nil
        flowChips.forEach { $0.removeFromSuperview() }
        flowChips = []
        if task.isTodo, task.status != .trashed {
            let id = task.id
            func add(_ title: String, image: NSImage?, detail: String? = nil, dim: Bool = false, menu: @escaping () -> NSMenu) {
                var chip: ChipButton?
                chip = ChipButton(title: title, symbol: "circle", color: Theme.secondary, detail: detail,
                                  titleColor: dim ? Theme.secondary : Theme.text, image: image) {
                    guard let chip else { return }
                    menu().popUp(positioning: nil, at: NSPoint(x: 0, y: chip.bounds.height + 4), in: chip)
                }
                addSubview(chip!)
                flowChips.append(chip!)
            }
            let reload: () -> Void = { [weak self] in self?.onReload?() }
            add(task.flow.title, image: WorkflowIcons.flowImage(task.flow), detail: TaskStore.shared.waitingLabel(task)) {
                WorkflowMenus.status(for: [id], done: reload)
            }
            add(task.priority == .none ? "Priority" : task.priority.title, image: WorkflowIcons.priorityImage(task.priority), dim: task.priority == .none) {
                WorkflowMenus.priority(for: [id], done: reload)
            }
            add(task.estimate > 0 ? Duration.text(seconds: task.estimate * 60) + " estimate" : "Estimate",
                image: NSImage.symbol("hourglass", size: 12, weight: .medium, color: Theme.secondary), dim: task.estimate == 0) {
                WorkflowMenus.estimate(for: [id], done: reload)
            }
        }

        if task.isEvening || task.startDate != nil || task.bucket == .someday {
            let title: String
            let symbol: String
            let color: NSColor
            if task.isEvening { title = "This Evening"; symbol = "moon.fill"; color = Theme.evening }
            else if let start = task.startDate, start < Date().startOfDay.addingDays(1) { title = "Today"; symbol = "star.fill"; color = Theme.listColor(.today) }
            else if let start = task.startDate { title = Format.relativeDay(start); symbol = "calendar"; color = Theme.listColor(.upcoming) }
            else { title = "Someday"; symbol = "archivebox.fill"; color = Theme.listColor(.someday) }
            let timeText = task.reminder.map { r -> String in let f = DateFormatter(); f.timeStyle = .short; return "🔔 " + f.string(from: r) }
            let chip = ChipButton(title: title, symbol: symbol, color: color, detail: timeText, titleColor: Theme.text) { [weak self] in self?.whenTapped() }
            addSubview(chip)
            whenChip = chip
        }
        if let deadline = task.deadline {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, d MMM"
            let days = deadline.daysFromToday
            let relative = days == 0 ? "today" : (days < 0 ? "\(-days) day\(days == -1 ? "" : "s") ago" : "\(days) day\(days == 1 ? "" : "s") left")
            let chip = ChipButton(title: "Deadline: " + formatter.string(from: deadline), symbol: "flag.fill", color: Theme.deadline,
                                  detail: relative, titleColor: Theme.deadline) { [weak self] in self?.deadlineTapped() }
            addSubview(chip)
            deadlineChip = chip
        }
        if let rule = task.repeatRule {
            let chip = ChipButton(title: rule.summary, symbol: "repeat", color: Theme.secondary, detail: nil, titleColor: Theme.text) { [weak self] in
                guard let self else { return }
                TaskMenus.showRepeat(for: [self.task.id]) { self.onReload?() }
            }
            addSubview(chip)
            repeatChip = chip
        }
        let tracked = TaskStore.shared.trackedTime(task.id)
        if tracked >= 60 {
            let sessions = TaskStore.shared.timeEntries(for: task.id).count
            let chip = ChipButton(title: "Focused " + Duration.text(seconds: tracked), symbol: "timer", color: Theme.accent,
                                  detail: sessions == 1 ? "1 session" : "\(sessions) sessions", titleColor: Theme.text) { [weak self] in
                guard let self, let chip = self.timeChip else { return }
                TaskMenus.timeMenu(for: self.task).popUp(positioning: nil, at: NSPoint(x: 0, y: chip.bounds.height + 4), in: chip)
            }
            addSubview(chip)
            timeChip = chip
        }
        if let projectID = task.projectID, let project = TaskStore.shared.task(projectID) {
            breadcrumb.title = project.title + "  ›"
            breadcrumb.image = NSImage.symbol("circle", size: 11, weight: .medium, color: Theme.secondary)
            breadcrumb.isHidden = false
        } else if let areaID = task.areaID, let area = TaskStore.shared.area(areaID) {
            breadcrumb.title = area.title + "  ›"
            breadcrumb.image = NSImage.symbol("shippingbox", size: 11, weight: .medium, color: Theme.secondary)
            breadcrumb.isHidden = false
        } else {
            breadcrumb.isHidden = true
        }
        whenIcon.isHidden = whenChip != nil
        deadlineIcon.isHidden = deadlineChip != nil
        remindIcon.isHidden = !task.isTodo || task.status != .open
        remindIcon.image = NSImage.symbol(task.reminder == nil ? "bell" : "bell.fill", size: 14, weight: .medium,
                                          color: task.reminder == nil ? Theme.secondary : Theme.accent)
        tagIcon.isHidden = showsTags
        checklistIcon.isHidden = showsChecklist
        aiIcon.isHidden = !Preferences.aiEnabled || task.status == .trashed
        restoreButton.isHidden = task.status != .trashed
        tagsField.isHidden = !showsTags
        addChecklistField.isHidden = !showsChecklist
        addChecklistHost.isHidden = !showsChecklist
        needsLayout = true
    }

    func focus(_ target: EditorFocus) {
        switch target {
        case .title:
            window?.makeFirstResponder(titleField)
            // Things: a new to-do's placeholder title is selected so typing replaces it;
            // an existing title gets the caret at the end, never a full selection.
            if task.title == "New To-Do" {
                titleField.currentEditor()?.selectAll(nil)
            } else if let editor = titleField.currentEditor() {
                editor.selectedRange = NSRange(location: (titleField.stringValue as NSString).length, length: 0)
            }
        case .notes: window?.makeFirstResponder(notesTextView)
        case .tags:
            showsTags = true
            refreshControls()
            onHeightChange?()
            window?.makeFirstResponder(tagsField)
        case .checklist:
            showsChecklist = true
            refreshControls()
            onHeightChange?()
            window?.makeFirstResponder(addChecklistField)
        }
    }

    private func rebuildChecklist() {
        checklistRows.forEach { $0.removeFromSuperview() }
        checklistRows.removeAll()
        checklistFields.removeAll()
        for (index, item) in task.checklist.enumerated() {
            let row = ChecklistRowView(item: item, index: index)
            row.field.delegate = self
            row.onToggle = { [weak self] in
                guard let self else { return }
                TaskStore.shared.toggleChecklistItem(self.task.id, itemID: item.id)
                self.onReload?()
            }
            row.onDragMove = { [weak self] from, delta in self?.dragChecklist(from: from, deltaY: delta) }
            row.onDragEnd = { [weak self] from in self?.finishChecklistDrag(from: from) }
            addSubview(row)
            checklistRows.append(row)
            checklistFields.append(row.field)
        }
        needsLayout = true
    }

    // MARK: - Checklist drag to reorder

    private var dragTarget: Int?

    private func dragChecklist(from: Int, deltaY: CGFloat) {
        guard checklistRows.indices.contains(from) else { return }
        let target = max(0, min(checklistRows.count - 1, from + Int((deltaY / ChecklistRowView.height).rounded())))
        dragTarget = target
        // Live preview: shift the other rows out of the way.
        for (i, row) in checklistRows.enumerated() {
            var slot = i
            if i == from { slot = target }
            else if from < target, i > from, i <= target { slot = i - 1 }
            else if from > target, i >= target, i < from { slot = i + 1 }
            if i == from {
                row.frame.origin.y = checklistTop + CGFloat(from) * ChecklistRowView.height + deltaY
            } else {
                row.animator().frame.origin.y = checklistTop + CGFloat(slot) * ChecklistRowView.height
            }
        }
    }

    private func finishChecklistDrag(from: Int) {
        defer { dragTarget = nil }
        guard let target = dragTarget, target != from else { needsLayout = true; return }
        TaskStore.shared.moveChecklistItem(task.id, from: from, to: target)
        onReload?()
    }

    private var checklistTop: CGFloat = 0

    /// Refreshes from the store without clobbering a field that has focus.
    func update(task: TaskItem) {
        self.task = task
        let focused = window?.firstResponder
        if focused !== titleField.currentEditor(), titleField.stringValue != task.title { titleField.stringValue = task.title }
        if focused !== notesTextView, notesSaveTimer == nil, notesTextView.string != task.notes { notesTextView.setMarkdown(task.notes) }
        rebuildTagTokens()
        checkbox.isChecked = task.isCompleted
        showsTags = showsTags || !task.tags.isEmpty
        showsChecklist = showsChecklist || !task.checklist.isEmpty
        refreshControls()
        let editingChecklist = checklistFields.contains { $0.currentEditor() != nil && $0.currentEditor() === focused }
        if !editingChecklist { rebuildChecklist() }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let x = Self.textX
        checkbox.frame = NSRect(x: 4, y: 16, width: 15, height: 15)
        titleField.frame = NSRect(x: x - 2, y: 13, width: width - x - 30, height: 22)
        expandButton.frame = NSRect(x: width - 22, y: 15, width: 16, height: 16)

        var y: CGFloat = 42
        let notes = notesHeight(width: width)
        notesTextView.frame = NSRect(x: x, y: y, width: width - x - 16, height: notes)
        y += notes + 10

        if showsChecklist {
            // Things: hairline-separated rows aligned with the title text.
            checklistTop = y
            let rowWidth = width - x - 16
            for (index, row) in checklistRows.enumerated() where dragTarget == nil {
                row.frame = NSRect(x: x, y: y + CGFloat(index) * ChecklistRowView.height, width: rowWidth, height: ChecklistRowView.height)
            }
            y += CGFloat(checklistRows.count) * ChecklistRowView.height
            addChecklistHost.frame = NSRect(x: x, y: y, width: rowWidth, height: ChecklistRowView.height)
            addChecklistField.frame = NSRect(x: x + 20, y: y + (ChecklistRowView.height - 19) / 2, width: rowWidth - 48, height: 19)
            y += ChecklistRowView.height + 6
        }
        if showsTags {
            // Things: filled tag tokens followed by an inline caret for the next tag.
            var tx = x
            for token in tagTokens {
                let w = token.intrinsicContentSize.width
                token.frame = NSRect(x: tx, y: y + 3, width: w, height: 24)
                tx += w + 6
            }
            tagsField.frame = NSRect(x: tx, y: y + 6, width: max(120, width - tx - 16), height: 19)
            y += 32
        }

        let cardBottom = bounds.height - Self.breadcrumbHeight
        let rows = [whenChip, deadlineChip, repeatChip, timeChip].compactMap { $0 }
        var rowY = cardBottom - 12 - CGFloat(max(1, rows.count + (flowChips.isEmpty ? 0 : 1))) * 28
        if !flowChips.isEmpty {
            var chipX = x - 4
            for chip in flowChips {
                let chipWidth = chip.intrinsicContentSize.width
                chip.frame = NSRect(x: chipX, y: rowY + 2, width: chipWidth, height: 24)
                chipX += chipWidth + 4
            }
            rowY += 28
        }
        for chip in rows {
            chip.frame = NSRect(x: x - 4, y: rowY + 2, width: chip.intrinsicContentSize.width, height: 24)
            rowY += 28
        }
        let bottom = cardBottom - 36
        if !restoreButton.isHidden {
            restoreButton.frame = NSRect(x: x, y: bottom, width: 90, height: 22)
        }
        let crumbWidth = breadcrumb.intrinsicContentSize.width + 8
        breadcrumb.frame = NSRect(x: width - crumbWidth, y: cardBottom + 6, width: crumbWidth, height: 20)
        var iconX = width - 30
        for icon in [remindIcon, deadlineIcon, checklistIcon, tagIcon, whenIcon, aiIcon] where !icon.isHidden {
            icon.frame = NSRect(x: iconX, y: bottom - 1, width: 26, height: 24)
            iconX -= 32
        }
    }

    // MARK: - Actions

    @objc private func whenTapped() {
        let anchor = whenChip ?? whenIcon
        WhenPicker.show(mode: .when, current: task.startDate, reminder: task.reminder, relativeTo: anchor.bounds, of: anchor) { [weak self] choice in
            guard let self else { return }
            choice.applyWhen(to: [self.task.id])
            self.onReload?()
        }
    }

    @objc private func remindTapped() {
        RemindPicker.show(current: task.reminder, relativeTo: remindIcon.bounds, of: remindIcon) { [weak self] date in
            guard let self else { return }
            RemindPicker.apply(date, to: [self.task.id])
            self.onReload?()
        }
    }

    @objc private func deadlineTapped() {
        let anchor = deadlineChip ?? deadlineIcon
        WhenPicker.show(mode: .deadline, current: task.deadline, relativeTo: anchor.bounds, of: anchor) { [weak self] choice in
            guard let self else { return }
            choice.applyDeadline(to: [self.task.id])
            self.onReload?()
        }
    }

    @objc private func breadcrumbTapped() {
        commitAll()
        if let projectID = task.projectID { AppState.shared.selection = .project(projectID) }
        else if let areaID = task.areaID { AppState.shared.selection = .area(areaID) }
    }

    @objc private func tagsTapped() {
        SearchListPopover.show(.tags(ids: [task.id]) { [weak self] in self?.onReload?() }, relativeTo: tagIcon.bounds, of: tagIcon)
    }
    @objc private func checklistTapped() { focus(.checklist) }
    @objc private func aiTapped() { onAIEnhance?(task) }

    @objc private func expandTapped() {
        commitAll()
        NotificationCenter.default.post(name: .openNotePage, object: task.id)
    }

    @objc private func removeChecklistItem(_ sender: NSButton) {
        guard sender.tag < task.checklist.count else { return }
        TaskStore.shared.deleteChecklistItem(task.id, itemID: task.checklist[sender.tag].id)
        onReload?()
    }

    @objc private func restoreTapped() {
        TaskStore.shared.restore(task.id)
        onClose?()
        onReload?()
    }

    private func notesChanged() {
        notesSaveTimer?.invalidate()
        notesSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.saveNotes() }
        if abs(bodyHeight(width: bounds.width) - lastHeight) > 0.5 { onHeightChange?() }
    }

    private func saveNotes() {
        notesSaveTimer?.invalidate()
        notesSaveTimer = nil
        if notesTextView.string != task.notes {
            TaskStore.shared.setNotes(task.id, notesTextView.string)
            if let fresh = TaskStore.shared.task(task.id) { task = fresh }
        }
    }

    @objc private func closeTapped() {
        commitAll()
        onClose?()
    }

    /// Writes every pending field. Called before the editor closes.
    func commitAll() {
        let title = titleField.stringValue
        if !title.trimmingCharacters(in: .whitespaces).isEmpty, title != task.title { TaskStore.shared.setTitle(task.id, title) }
        saveNotes()
        if !tagsField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { commitTagInput() }
        let pending = addChecklistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            addChecklistField.stringValue = ""
            TaskStore.shared.addChecklistItem(task.id, title: pending)
        }
        for field in checklistFields {
            guard let id = field.identifier?.rawValue.replacingOccurrences(of: "check:", with: ""),
                  let item = task.checklist.first(where: { $0.id == id }), field.stringValue != item.title else { continue }
            TaskStore.shared.renameChecklistItem(task.id, itemID: id, title: field.stringValue)
        }
        if let fresh = TaskStore.shared.task(task.id) { task = fresh }
    }

    // MARK: - Field delegates

    func controlTextDidBeginEditing(_ notification: Notification) { refreshChecklistFocus() }

    private func refreshChecklistFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for row in self.checklistRows.compactMap({ $0 as? ChecklistRowView }) { row.needsDisplay = true }
            self.addChecklistHost.needsDisplay = true
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        refreshChecklistFocus()
        if let field = notification.object as? NSTextField, let id = field.identifier?.rawValue, id.hasPrefix("check:"),
           field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            // Things: clearing a checklist item's text removes it.
            TaskStore.shared.deleteChecklistItem(task.id, itemID: String(id.dropFirst(6)))
            onReload?()
            return
        }
        guard let field = notification.object as? NSTextField else { return }
        if field === titleField {
            TaskStore.shared.setTitle(task.id, titleField.stringValue)
            if let fresh = TaskStore.shared.task(task.id) { task = fresh }
        } else if field === tagsField {
            commitTagInput()
        } else if let id = field.identifier?.rawValue, id.hasPrefix("check:") {
            TaskStore.shared.renameChecklistItem(task.id, itemID: String(id.dropFirst(6)), title: field.stringValue)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === tagsField, tagsField.stringValue.hasSuffix(",") else { return }
        commitTagInput()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === tagsField, commandSelector == #selector(NSResponder.deleteBackward(_:)), tagsField.stringValue.isEmpty,
           let last = task.tags.last {
            TaskStore.shared.setTags(task.id, task.tags.filter { $0 != last })
            if let fresh = TaskStore.shared.task(task.id) { task = fresh }
            rebuildTagTokens()
            onReload?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeTapped()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === titleField { closeTapped(); return true }
            if control === tagsField {
                commitTagInput()
                DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.tagsField) }
                return true
            }
            if let id = control.identifier?.rawValue, id.hasPrefix("check:") {
                window?.makeFirstResponder(addChecklistField)
                return true
            }
            if control === addChecklistField {
                let value = addChecklistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { window?.makeFirstResponder(notesTextView); return true }
                addChecklistField.stringValue = ""
                TaskStore.shared.addChecklistItem(task.id, title: value)
                onReload?()
                DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.addChecklistField) }
                return true
            }
        }
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeTapped()
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === notesTextView else { return }
        saveNotes()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { NSWorkspace.shared.open(url); return true }
        return false
    }
}

/// A value row in the card ("★ Today", "⚑ Deadline: Fri, 6 Nov  today"). Click to change.
final class ChipButton: NSButton {
    private let handler: () -> Void
    private let symbolImage: NSImage?
    private let detail: String?
    private let titleColor: NSColor
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, color: NSColor, detail: String? = nil, titleColor: NSColor = Theme.text,
         image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        self.detail = detail
        self.titleColor = titleColor
        symbolImage = image ?? NSImage.symbol(symbol, size: 13, weight: .semibold, color: color)
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(fire)
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var titleAttributes: [NSAttributedString.Key: Any] { [.font: Fonts.medium(13.5), .foregroundColor: titleColor] }
    private var detailAttributes: [NSAttributedString.Key: Any] { [.font: Fonts.regular(13), .foregroundColor: Theme.secondary] }

    override var intrinsicContentSize: NSSize {
        var width = 30 + ceil((title as NSString).size(withAttributes: titleAttributes).width) + 10
        if let detail { width += ceil((detail as NSString).size(withAttributes: detailAttributes).width) + 8 }
        return NSSize(width: width, height: 24)
    }

    @objc private func fire() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.rowHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        symbolImage?.draw(in: NSRect(x: 4, y: (bounds.height - 15) / 2, width: 15, height: 15))
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(at: NSPoint(x: 26, y: (bounds.height - titleSize.height) / 2), withAttributes: titleAttributes)
        if let detail {
            let size = (detail as NSString).size(withAttributes: detailAttributes)
            (detail as NSString).draw(at: NSPoint(x: 26 + titleSize.width + 8, y: (bounds.height - size.height) / 2), withAttributes: detailAttributes)
        }
    }

    override var isFlipped: Bool { false }
}


/// One checklist line, Things style: hairline above, small blue ring, text, and a
/// ≡ handle (on hover/focus) that drags the row to a new position.
final class ChecklistRowView: NSView {
    static let height: CGFloat = 28
    let field = NSTextField()
    private let item: ChecklistItem
    private let index: Int
    var onToggle: (() -> Void)?
    var onDragMove: ((Int, CGFloat) -> Void)?
    var onDragEnd: ((Int) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragStartY: CGFloat?
    override var isFlipped: Bool { true }

    init(item: ChecklistItem, index: Int) {
        self.item = item
        self.index = index
        super.init(frame: .zero)
        field.stringValue = item.title
        field.font = Fonts.regular(14)
        field.textColor = item.done ? Theme.secondary : Theme.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.identifier = NSUserInterfaceItemIdentifier("check:" + item.id)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var isEditing: Bool { field.currentEditor() != nil && window?.firstResponder === field.currentEditor() }
    private var ringRect: NSRect { NSRect(x: 2, y: (bounds.height - 10) / 2, width: 10, height: 10) }
    private var handleRect: NSRect { NSRect(x: bounds.width - 26, y: 0, width: 26, height: bounds.height) }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 20, y: (bounds.height - 19) / 2, width: bounds.width - 52, height: 19)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if isEditing || dragStartY != nil {
            let rect = bounds.insetBy(dx: -8, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            Theme.rowHover.setFill(); path.fill()
            Theme.separator.setStroke(); path.lineWidth = 1; path.stroke()
        } else {
            Theme.cardSeparator.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        let ring = NSBezierPath(ovalIn: ringRect)
        if item.done {
            Theme.accent.setFill(); ring.fill()
            let check = NSBezierPath()
            let r = ringRect
            check.move(to: NSPoint(x: r.minX + 2.5, y: r.midY))
            check.line(to: NSPoint(x: r.minX + 4.3, y: r.maxY - 2.6))
            check.line(to: NSPoint(x: r.maxX - 2.3, y: r.minY + 2.6))
            check.lineWidth = 1.4
            NSColor.white.setStroke(); check.stroke()
        } else {
            Theme.accent.setStroke(); ring.lineWidth = 1.5; ring.stroke()
        }
        if hovering || isEditing || dragStartY != nil {
            NSImage.symbol("line.3.horizontal", size: 11, weight: .regular, color: Theme.tertiary)?
                .draw(in: NSRect(x: handleRect.midX - 7, y: handleRect.midY - 5, width: 14, height: 10))
        }
    }

    override func resetCursorRects() {
        addCursorRect(handleRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if ringRect.insetBy(dx: -6, dy: -6).contains(point) { onToggle?(); return }
        if handleRect.contains(point) {
            dragStartY = event.locationInWindow.y
            NSCursor.closedHand.push()
            needsDisplay = true
            return
        }
        window?.makeFirstResponder(field)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartY else { return }
        onDragMove?(index, start - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartY != nil else { return }
        dragStartY = nil
        NSCursor.pop()
        needsDisplay = true
        onDragEnd?(index)
    }
}

/// The empty "next item" line under a checklist: hairline, ring, highlight when focused.
final class ChecklistAddRowBackground: NSView {
    weak var field: NSTextField?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let editing = field.map { $0.currentEditor() != nil && window?.firstResponder === $0.currentEditor() } ?? false
        if editing {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: -8, dy: 1), xRadius: 7, yRadius: 7)
            Theme.rowHover.setFill(); path.fill()
            Theme.separator.setStroke(); path.lineWidth = 1; path.stroke()
            NSImage.symbol("line.3.horizontal", size: 11, weight: .regular, color: Theme.tertiary)?
                .draw(in: NSRect(x: bounds.width - 20, y: bounds.midY - 5, width: 14, height: 10))
        } else {
            Theme.cardSeparator.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: (bounds.height - 10) / 2, width: 10, height: 10))
        Theme.accent.withAlphaComponent(editing ? 1 : 0.5).setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if let field { window?.makeFirstResponder(field) }
    }
}
