import AppKit

final class TaskRowView: HoverRowView, NSDraggingSource {
    override var isFlipped: Bool { true }
    let task: TaskItem
    var isSelectedRow = false {
        didSet { needsDisplay = true }
    }
    var isOpenRow = false {
        didSet { needsDisplay = true }
    }

    var onSelect: ((TaskItem, NSEvent) -> Void)?
    var onOpen: ((TaskItem) -> Void)?
    var onToggle: ((TaskItem, Bool) -> Void)?
    var onOpenTag: ((String) -> Void)?
    var onContextMenu: ((TaskItem, NSEvent) -> Void)?
    var dragIDs: (() -> [String])?

    private let checkbox = CheckboxView()
    private let titleLabel = NSTextField.label("", font: Fonts.regular(14), color: Theme.text)
    private let notesLabel = NSTextField.label("", font: Fonts.regular(11.5), color: Theme.secondary)
    private let deadlineLabel = NSTextField.label("", font: Fonts.regular(11.5), color: Theme.deadline)
    private let projectLabel = NSTextField.label("", font: Fonts.regular(11), color: Theme.secondary)
    private let checklistLabel = NSTextField.label("", font: Fonts.regular(10.5), color: Theme.tertiary)
    private let leadingLabel = NSTextField.label("", font: Fonts.medium(13), color: Theme.accent)
    private let repeatIcon = NSImageView()
    private let eveningIcon = NSImageView()
    private let ring = ProgressRing()
    private let noteIcon = NSImageView()
    private let focusIcon = NSImageView()
    private let checklistIcon = NSImageView()
    private let dateChip = TagChip("")
    private let countChip = TagChip("")
    private var tagChips: [TagChip] = []
    private var mouseDownPoint: NSPoint?

    private let showProjectName: Bool
    private let leadingText: String?
    private let showsDateChip: Bool
    private let hidesTodayStar: Bool
    private let todayStar = NSImageView()
    private let reminderLabel = NSTextField.label("", font: Fonts.medium(11.5), color: Theme.secondary)

    private let isNew: Bool
    private let newDot = FillView(fill: Theme.listColor(.today))

    init(task: TaskItem, showProjectName: Bool, leadingText: String? = nil, showsDateChip: Bool = true, isNew: Bool = false, hidesTodayStar: Bool = false) {
        self.isNew = isNew
        self.hidesTodayStar = hidesTodayStar
        self.task = task
        self.showProjectName = showProjectName
        self.leadingText = leadingText
        self.showsDateChip = showsDateChip
        super.init(frame: .zero)

        checkbox.isSquare = true
        checkbox.isChecked = task.isCompleted
        checkbox.isCanceled = task.isCanceled
        checkbox.tint = task.isProject ? Theme.projectColor(for: task.id) : Theme.accent
        checkbox.onToggle = { [weak self] alternate in
            guard let self else { return }
            self.onToggle?(self.task, alternate)
        }
        addSubview(checkbox)
        addSubview(titleLabel)
        addSubview(notesLabel)
        addSubview(deadlineLabel)
        addSubview(projectLabel)
        addSubview(checklistLabel)

        if task.isCompleted && !task.isProject {
            // Things: completed titles are greyed; only canceled ones are struck through.
            let inLogbook = (MainWindowController.active ?? .shared).state.selection == .builtin(.logbook)
            var attributes: [NSAttributedString.Key: Any] = [.font: Fonts.regular(14), .foregroundColor: inLogbook && !task.isCanceled ? Theme.text : Theme.secondary]
            if task.isCanceled {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = Theme.secondary
            }
            titleLabel.attributedStringValue = NSAttributedString(string: task.title, attributes: attributes)
        } else {
            let untitled = task.title.trimmingCharacters(in: .whitespaces).isEmpty
            titleLabel.stringValue = untitled ? "New To-Do" : task.title
            titleLabel.font = task.isProject ? Fonts.semibold(14) : Fonts.regular(14)
            // Things shows an untitled to-do as a grey placeholder.
            titleLabel.textColor = untitled ? Theme.tertiary : Theme.text
        }
        titleLabel.lineBreakMode = .byTruncatingTail

        // Things: notes and checklists show as small icons after the title, not a preview line.
        notesLabel.isHidden = true
        if !task.notes.isEmpty {
            noteIcon.image = NSImage.symbol("doc", size: 10, weight: .regular, color: Theme.tertiary)
            addSubview(noteIcon)
        }

        deadlineLabel.isHidden = task.deadline == nil
        if let deadline = task.deadline {
            let urgent = (deadline.isPast || deadline.isToday) && task.isOpen
            let color = urgent ? Theme.deadline : Theme.secondary
            let attachment = NSTextAttachment()
            attachment.image = NSImage.symbol(urgent ? "flag.fill" : "flag", size: 11, weight: .semibold, color: color)
            attachment.bounds = NSRect(x: 0, y: -1.5, width: 12, height: 12)
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " " + deadlineLabelText(deadline), attributes: [
                .font: Fonts.medium(12.5), .foregroundColor: color]))
            deadlineLabel.attributedStringValue = text
        }

        let projectName = task.projectID.flatMap { TaskStore.shared.task($0)?.title }
            ?? task.areaID.flatMap { TaskStore.shared.area($0)?.title }
        projectLabel.stringValue = showProjectName ? (projectName ?? "") : ""
        projectLabel.isHidden = projectLabel.stringValue.isEmpty

        if let leadingText {
            leadingLabel.stringValue = leadingText
            addSubview(leadingLabel)
        }
        if task.isOpen, task.isTodo, task.isDueToday, !hidesTodayStar {
            todayStar.image = NSImage.symbol(task.isEvening ? "moon.fill" : "star.fill", size: 11, weight: .semibold,
                                             color: task.isEvening ? Theme.evening : Theme.listColor(.today))
            addSubview(todayStar)
        }
        if isNew {
            newDot.wantsLayer = true
            newDot.layer?.cornerRadius = 4
            addSubview(newDot)
        }
        if task.isOpen, let reminder = task.reminder {
            let f = DateFormatter(); f.timeStyle = .short
            let attachment = NSTextAttachment()
            attachment.image = NSImage.symbol("bell.fill", size: 9, weight: .semibold, color: Theme.secondary)
            attachment.bounds = NSRect(x: 0, y: -1, width: 9, height: 9)
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " " + f.string(from: reminder), attributes: [.font: Fonts.medium(11.5), .foregroundColor: Theme.secondary]))
            reminderLabel.attributedStringValue = text
            addSubview(reminderLabel)
        }
        // Things shows a grey date chip before the title for to-dos scheduled later (e.g. "Nov 13").
        if leadingText == nil, task.isOpen, task.bucket == .scheduled, let start = task.startDate,
           start >= Date().startOfDay.addingDays(1), showsDateChip {
            dateChip.text = start.daysFromToday < 7 ? start.weekdayString.prefix(3).description : start.monthDayString
            addSubview(dateChip)
        }

        if !task.tags.isEmpty {
            for tag in task.tags {
                let chip = TagChip(tag)
                chip.isOutlined = true
                chip.tint = TaskStore.shared.tagTint(tag)
                chip.onClick = { [weak self] value in self?.onOpenTag?(value) }
                addSubview(chip)
                tagChips.append(chip)
            }
        }

        checklistLabel.isHidden = true
        if !task.checklist.isEmpty {
            checklistIcon.image = NSImage.symbol("list.bullet", size: 10, weight: .regular, color: Theme.tertiary)
            addSubview(checklistIcon)
        }

        if FocusTimer.shared.taskID == task.id {
            focusIcon.image = NSImage.symbol("timer", size: 10, weight: .semibold, color: Theme.accent)
            addSubview(focusIcon)
        }
        if task.repeatRule != nil {
            repeatIcon.image = NSImage.symbol("repeat", size: 9, weight: .semibold, color: Theme.tertiary)
            addSubview(repeatIcon)
        }
        if task.isEvening && task.isOpen {
            eveningIcon.image = NSImage.symbol("moon.fill", size: 9, weight: .semibold, color: Theme.evening)
            addSubview(eveningIcon)
        }

        if task.isProject {
            let open = TaskStore.shared.children(of: task.id).filter { $0.isTodo && $0.isOpen }.count
            countChip.text = "\(open)"
            countChip.isOutlined = true
            countChip.isSquare = true
            addSubview(countChip)
            checkbox.isHidden = true
            let progress = TaskStore.shared.projectProgress(task.id)
            ring.progress = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
            ring.color = Theme.accent
            addSubview(ring)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func deadlineLabelText(_ date: Date) -> String {
        if date.isToday { return "today" }
        if date.isPast {
            let days = -date.daysFromToday
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
        let days = date.daysFromToday
        if days < 15 { return days == 1 ? "1 day left" : "\(days) days left" }
        return date.monthDayString
    }

    static func height(for task: TaskItem, showsParent: Bool = false) -> CGFloat {
        let scale = Fonts.scale
        var height: CGFloat = Layout.rowHeight * scale
        if showsParent && (task.projectID != nil || task.areaID != nil) { height += 13 * scale }
        return ceil(height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: -6, dy: 1)
        if isSelectedRow {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            Theme.rowSelection.setFill()
            path.fill()
        } else if isHovered {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            Theme.rowHover.setFill()
            path.fill()
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var textX: CGFloat = 21
        let mid = Layout.rowHeight * Fonts.scale / 2
        if task.isProject {
            ring.frame = NSRect(x: -1, y: mid - 8.5, width: 17, height: 17)
        } else {
            checkbox.frame = NSRect(x: 0, y: mid - 7, width: 14, height: 14)
        }
        if leadingText != nil {
            let w = leadingLabel.fittingWidth + 2
            leadingLabel.frame = NSRect(x: textX, y: 5 * Fonts.scale, width: w, height: 18 * Fonts.scale)
            textX += w + 6
        }
        if todayStar.superview != nil {
            todayStar.frame = NSRect(x: textX, y: 8 * Fonts.scale, width: 12, height: 12 * Fonts.scale)
            textX += 18
        }
        if newDot.superview != nil {
            newDot.frame = NSRect(x: textX, y: 10 * Fonts.scale, width: 8, height: 8)
            textX += 14
        }
        if reminderLabel.superview != nil {
            let w = reminderLabel.attributedStringValue.size().width + 4
            reminderLabel.frame = NSRect(x: textX, y: 6 * Fonts.scale, width: w, height: 16 * Fonts.scale)
            textX += w + 6
        }
        if dateChip.superview != nil {
            let size = dateChip.intrinsicContentSize
            dateChip.frame = NSRect(x: textX, y: 6 * Fonts.scale, width: size.width, height: 16 * Fonts.scale)
            textX += size.width + 6
        }
        var rightInset: CGFloat = 4
        if !deadlineLabel.isHidden {
            let deadlineWidth = ceil(deadlineLabel.attributedStringValue.size().width) + 4
            deadlineLabel.frame = NSRect(x: width - deadlineWidth + 2, y: 6 * Fonts.scale, width: deadlineWidth, height: 16 * Fonts.scale)
            rightInset = deadlineWidth + 12
        }

        let trailingIcons = [focusIcon, noteIcon, checklistIcon, repeatIcon, eveningIcon].filter { $0.superview != nil }
        let countWidth: CGFloat = countChip.superview != nil ? countChip.intrinsicContentSize.width + 6 : 0
        var chipsWidth: CGFloat = 0
        for chip in tagChips { chipsWidth += chip.intrinsicContentSize.width + 5 }
        let reserved = CGFloat(trailingIcons.count) * 16 + chipsWidth + countWidth + 4
        let maxTitle = max(60, width - textX - rightInset - reserved)
        let titleWidth = min(maxTitle, textWidth(titleLabel.stringValue, font: titleLabel.font) - 8)
        titleLabel.frame = NSRect(x: textX, y: 5 * Fonts.scale, width: titleWidth, height: 19 * Fonts.scale)

        var x = textX + titleWidth + 3
        if countChip.superview != nil {
            countChip.frame = NSRect(x: x, y: 6 * Fonts.scale, width: countChip.intrinsicContentSize.width, height: 16 * Fonts.scale)
            x += countChip.intrinsicContentSize.width + 6
        }
        for icon in trailingIcons {
            icon.frame = NSRect(x: x, y: 8 * Fonts.scale, width: 12, height: 12 * Fonts.scale)
            x += 16
        }
        for chip in tagChips {
            let size = chip.intrinsicContentSize
            guard x + size.width < width - rightInset else { chip.isHidden = true; continue }
            chip.frame = NSRect(x: x, y: 6 * Fonts.scale, width: size.width, height: 16 * Fonts.scale)
            x += size.width + 5
        }

        if !projectLabel.isHidden {
            projectLabel.frame = NSRect(x: textX, y: 23 * Fonts.scale, width: max(80, width - textX - 12), height: 14 * Fonts.scale)
        }
    }

    private func textWidth(_ text: String, font: NSFont?) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? Fonts.regular(11.5)]
        return ceil((text as NSString).size(withAttributes: attributes).width) + 12
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            onOpen?(task)
            return
        }
        onSelect?(task, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(task, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, task.status != .trashed else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil

        let ids = dragIDs?() ?? [task.id]
        let item = NSPasteboardItem()
        let data = (try? JSONSerialization.data(withJSONObject: ids)) ?? Data()
        item.setData(data, forType: TaskDrag.type)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = snapshot()
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        let wasSelected = isSelectedRow
        isSelectedRow = true
        cacheDisplay(in: bounds, to: rep)
        isSelectedRow = wasSelected
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}
