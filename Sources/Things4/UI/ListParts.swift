import AppKit
import UniformTypeIdentifiers

/// Pasteboard type used when dragging to-dos around the app.
enum TaskDrag {
    static let type = NSPasteboard.PasteboardType("com.tanay.things4.tasks")

    static func write(_ ids: [String], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let data = (try? JSONSerialization.data(withJSONObject: ids)) ?? Data()
        pasteboard.setData(data, forType: type)
    }

    static func read(_ pasteboard: NSPasteboard) -> [String] {
        guard let data = pasteboard.data(forType: type),
              let ids = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return ids
    }
}

final class AddTaskRow: HoverRowView {
    var onSubmit: ((String) -> Void)?
    let field = NSTextField()
    private var plusIcon: NSImageView?

    init(placeholder: String, tint: NSColor = Theme.accent) {
        super.init(frame: .zero)
        let plus = NSImageView()
        plus.image = NSImage.symbol("plus", size: 11, weight: .medium, color: tint)
        addSubview(plus)
        plusIcon = plus

        field.font = Fonts.regular(13.5)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.text
        field.target = self
        field.action = #selector(submit)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        plusIcon?.frame = NSRect(x: 6, y: 12, width: 12, height: 12)
        field.frame = NSRect(x: 30, y: 8, width: bounds.width - 36, height: 20)
    }

    @objc private func submit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            window?.makeFirstResponder(nil)
            return
        }
        field.stringValue = ""
        onSubmit?(value)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.field)
        }
    }
}

final class SectionHeaderView: FlippedView {
    private let label = NSTextField.label("", font: Fonts.semibold(12), color: Theme.secondary)
    private let countLabel = NSTextField.label("", font: Fonts.regular(11), color: Theme.tertiary)
    private let iconView = NSImageView()
    private let hasIcon: Bool

    init(title: String, detail: String = "", symbol: String? = nil, color: NSColor = Theme.tertiary, large: Bool = false) {
        hasIcon = symbol != nil
        super.init(frame: .zero)
        label.stringValue = large ? title : title.uppercased()
        label.font = large ? Fonts.semibold(15) : Fonts.semibold(10.5)
        label.textColor = large ? Theme.text : Theme.tertiary
        countLabel.stringValue = detail
        if let symbol {
            iconView.image = NSImage.symbol(symbol, size: large ? 13 : 10, weight: .semibold, color: color)
            addSubview(iconView)
        }
        addSubview(label)
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let x: CGFloat = hasIcon ? 24 : 4
        if hasIcon { iconView.frame = NSRect(x: 4, y: bounds.height - 22, width: 16, height: 16) }
        label.frame = NSRect(x: x, y: bounds.height - 24, width: 320, height: 20)
        let countWidth = countLabel.fittingWidth
        countLabel.frame = NSRect(x: max(330, bounds.width - countWidth - 4), y: bounds.height - 21, width: countWidth, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class EmptyStateView: FlippedView {
    private let titleLabel = NSTextField.label("", font: Fonts.medium(14), color: Theme.secondary)
    private let subtitleLabel = NSTextField.label("", font: Fonts.regular(12), color: Theme.tertiary)

    init(title: String, subtitle: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        titleLabel.sizeToFit()
        subtitleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 4, y: 12)
        subtitleLabel.frame.origin = NSPoint(x: 4, y: 34)
    }
}

/// Things-style list header: icon or progress ring, big bold title with an inline
/// ••• button, and (for projects) the notes as editable Markdown right underneath.
final class ListHeaderView: FlippedView, NSTextViewDelegate {
    private let titleLabel = NSTextField.label("", font: Fonts.bold(22), color: Theme.text)
    private let subtitleLabel = NSTextField.label("", font: Fonts.regular(13), color: Theme.secondary)
    private let ring = ProgressRing()
    private let iconView = NSImageView()
    private let menuButton = IconButton(symbol: "ellipsis", size: 19, color: Theme.secondary, tooltip: "More")
    private let actionButton = FlatButton(title: "", symbol: nil, color: Theme.secondary, fontSize: 11.5)
    let notesView = MarkdownTextView()

    private let showsNotes: Bool
    private let hasRing: Bool
    private let hasIcon: Bool
    private var notesTimer: Timer?
    var onRing: (() -> Void)?
    var onAction: (() -> Void)?
    var onTitleEdit: ((String) -> Void)?
    var onNotesChange: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    static let notesSize: CGFloat = 14

    init(title: String, subtitle: String, notes: String, progress: Double?, color: NSColor,
         symbol: String? = nil, actionTitle: String? = nil, actionSymbol: String? = nil, showsNotes: Bool = false) {
        self.showsNotes = showsNotes
        hasRing = progress != nil
        hasIcon = symbol != nil && progress == nil
        super.init(frame: .zero)

        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        ring.progress = progress ?? 0
        ring.color = color
        ring.isHidden = progress == nil
        ring.onClick = { [weak self] in self?.onRing?() }
        ring.toolTip = "Complete project"
        ring.lineWidth = 2.5
        menuButton.image = NSImage.symbol("ellipsis", size: 18, weight: .black, color: Theme.secondary)

        if hasIcon, let symbol {
            iconView.image = NSImage.symbol(symbol, size: 22, weight: .semibold, color: color)
            addSubview(iconView)
        }
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(ring)

        if showsNotes {
            notesView.configure(baseSize: Self.notesSize)
            notesView.placeholderString = "Notes"
            notesView.textContainerInset = NSSize(width: 0, height: 2)
            notesView.textContainer?.lineFragmentPadding = 0
            notesView.setMarkdown(notes)
            notesView.delegate = self
            notesView.onChange = { [weak self] in self?.notesEdited() }
            addSubview(notesView)
        }

        menuButton.target = self
        menuButton.action = #selector(menuTapped)
        addSubview(menuButton)
        menuButton.isHidden = true

        if let actionTitle {
            actionButton.title = actionTitle
            if let actionSymbol {
                actionButton.image = NSImage.symbol(actionSymbol, size: 11, weight: .medium, color: Theme.secondary)
                actionButton.imagePosition = .imageLeading
            }
            actionButton.target = self
            actionButton.action = #selector(actionTapped)
            addSubview(actionButton)
        } else {
            actionButton.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func enableMenu() { menuButton.isHidden = false }

    private var titleBlock: CGFloat { subtitleLabel.isHidden ? 46 : 66 }

    static func height(notes: String, showsNotes: Bool, width: CGFloat) -> CGFloat {
        guard showsNotes else { return 56 }
        let probe = MarkdownTextView()
        probe.configure(baseSize: notesSize)
        probe.textContainerInset = NSSize(width: 0, height: 2)
        probe.textContainer?.lineFragmentPadding = 0
        probe.setMarkdown(notes.isEmpty ? "Notes" : notes)
        return 48 + max(22, probe.contentHeight(for: width - 4)) + 6
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        guard showsNotes else { return titleBlock + 10 }
        let text = notesView.contentHeight(for: width - 4)
        return 48 + max(22, text) + 6
    }

    private func notesEdited() {
        onHeightChange?()
        notesTimer?.invalidate()
        notesTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in self?.saveNotes() }
    }

    func saveNotes() {
        notesTimer?.invalidate()
        notesTimer = nil
        onNotesChange?(notesView.string)
    }

    func textDidEndEditing(_ notification: Notification) { saveNotes() }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { NSWorkspace.shared.open(url); return true }
        return false
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var x: CGFloat = 0
        // Measured from Things 3: 22pt ring/icon, title 28pt from the column edge.
        if hasRing {
            ring.frame = NSRect(x: -1, y: 11, width: 24, height: 24)
            x = 28
        } else if hasIcon {
            iconView.frame = NSRect(x: -3, y: 8, width: 30, height: 30)
            x = 28
        }
        let rightSpace: CGFloat = actionButton.isHidden ? 0 : 130
        let titleWidth = min(titleLabel.fittingWidth + 4, width - x - rightSpace - 34)
        titleLabel.frame = NSRect(x: x, y: 8, width: titleWidth, height: 30)
        menuButton.frame = NSRect(x: x + titleWidth + 2, y: 12, width: 30, height: 22)
        subtitleLabel.frame = NSRect(x: x, y: 44, width: width - x - rightSpace, height: 17)
        if !actionButton.isHidden {
            actionButton.frame = NSRect(x: width - 124, y: 14, width: 120, height: 22)
        }
        if showsNotes {
            let height = max(22, notesView.contentHeight(for: width - 4))
            notesView.frame = NSRect(x: 0, y: 46, width: width - 4, height: height)
        }
    }

    @objc private func actionTapped() { onAction?() }

    @objc private func menuTapped() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.height + 2), in: menuButton)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, titleLabel.frame.contains(point) {
            onTitleEdit?(titleLabel.stringValue)
            return
        }
        super.mouseDown(with: event)
    }
}

/// A section heading (in a project or an area). Accent title, divider and a ••• menu,
/// like Things. To-dos can be dropped under it.
final class HeadingRowView: HoverRowView {
    let heading: TaskItem
    var isSelectedRow = false { didSet { needsDisplay = true } }
    var isDropTarget = false { didSet { needsDisplay = true } }
    var onSelect: ((TaskItem, NSEvent) -> Void)?
    var onContextMenu: ((TaskItem, NSEvent) -> Void)?
    var onDoubleClick: ((TaskItem) -> Void)?

    private let titleLabel = NSTextField.label("", font: Fonts.semibold(14), color: Theme.accent)
    private let countLabel = NSTextField.label("", font: Fonts.regular(11), color: Theme.tertiary)
    private let menuButton = IconButton(symbol: "ellipsis", size: 13, color: Theme.accent, tooltip: "Heading actions")
    override var isFlipped: Bool { true }

    init(heading: TaskItem, openCount: Int) {
        self.heading = heading
        super.init(frame: .zero)
        titleLabel.stringValue = heading.title
        countLabel.stringValue = openCount > 0 ? "\(openCount)" : ""
        addSubview(titleLabel)
        addSubview(countLabel)
        menuButton.target = self
        menuButton.action = #selector(menuTapped)
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let titleWidth = min(titleLabel.fittingWidth + 2, bounds.width - 80)
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 25, width: titleWidth, height: 20)
        countLabel.frame = NSRect(x: titleWidth + 6, y: bounds.height - 22, width: 40, height: 15)
        menuButton.frame = NSRect(x: bounds.width - 28, y: bounds.height - 27, width: 24, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedRow || isDropTarget {
            let path = NSBezierPath(roundedRect: NSRect(x: -4, y: bounds.height - 30, width: bounds.width + 8, height: 28), xRadius: 6, yRadius: 6)
            (isDropTarget ? Theme.accent.withAlphaComponent(0.15) : Theme.rowSelection).setFill()
            path.fill()
        }
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func menuTapped() {
        guard let event = NSApp.currentEvent else { return }
        onContextMenu?(heading, event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(heading); return }
        onSelect?(heading, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(heading, event)
    }
}

/// The Things bottom bar: New To-Do, New Heading, When, Move, Quick Find, evenly spaced.
final class BottomToolbar: FillView {
    let addButton = IconButton(symbol: "plus", size: 15, color: Theme.secondary, tooltip: "New To-Do (⌘N)")
    let headingButton = IconButton(symbol: "plus.square", size: 15, color: Theme.secondary, tooltip: "New Heading (⇧⌘N)")
    let whenButton = IconButton(symbol: "calendar", size: 15, color: Theme.secondary, tooltip: "When (⌘S)")
    let moveButton = IconButton(symbol: "arrow.right", size: 15, color: Theme.secondary, tooltip: "Move (⇧⌘M)")
    let searchButton = IconButton(symbol: "magnifyingglass", size: 15, color: Theme.secondary, tooltip: "Quick Find (⌘F)")
    let deleteButton = IconButton(symbol: "trash", size: 15, color: Theme.secondary, tooltip: "Delete (⌘⌫)")
    let moreButton = IconButton(symbol: "ellipsis", size: 15, color: Theme.secondary, tooltip: "More")
    private var editing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill = Theme.window
        for button in [addButton, headingButton, whenButton, moveButton, searchButton, deleteButton, moreButton] {
            addSubview(button)
        }
        setEditing(false)
    }

    /// While a to-do is open Things shows only Move, Delete and •••.
    func setEditing(_ value: Bool) {
        editing = value
        [addButton, headingButton, whenButton, searchButton].forEach { $0.isHidden = value }
        deleteButton.isHidden = !value
        moreButton.isHidden = !value
        if value { moveButton.isEnabled = true; moveButton.alphaValue = 1 }
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelectionActive(_ active: Bool) {
        for button in [whenButton, moveButton] {
            button.isEnabled = active
            button.alphaValue = active ? 1 : 0.35
        }
    }

    func setHeadingAvailable(_ available: Bool) {
        headingButton.isHidden = editing || !available
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let buttons: [NSView] = editing ? [moveButton, deleteButton, moreButton]
                              : [addButton, headingButton, whenButton, moveButton, searchButton].filter { !$0.isHidden }
        // Things: fixed 88pt between toolbar icons, centred under the list.
        let step: CGFloat = editing ? 113 : 88
        let start = (bounds.width - step * CGFloat(buttons.count - 1)) / 2
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: start + step * CGFloat(index) - 14, y: 7, width: 28, height: 28)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// Document view for the list. It accepts task drops and draws the insertion line.
final class ListDocumentView: FlippedView {
    struct Slot {
        let id: String
        let frame: NSRect
        let headingID: String?
        let isHeading: Bool
    }

    var slots: [Slot] = []
    var canReorder = false
    var onDrop: ((_ ids: [String], _ beforeID: String?, _ headingID: String?) -> Void)?
    var onBackgroundClick: (() -> Void)?
    private var indicatorY: CGFloat?
    private var dropHeadingID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TaskDrag.type] + Links.pasteboardTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Files, web links or Mail messages dropped from another app.
    var onExternalDrop: ((_ items: [Links.Item], _ beforeID: String?, _ headingID: String?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onBackgroundClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let indicatorY else { return }
        let width = slots.first?.frame.width ?? bounds.width - 80
        let x = slots.first?.frame.minX ?? 40
        Theme.dropIndicator.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: indicatorY - 1, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(ovalIn: NSRect(x: x - 4, y: indicatorY - 4, width: 8, height: 8)).fill()
    }

    private func target(for point: NSPoint) -> (beforeID: String?, headingID: String?, y: CGFloat)? {
        guard canReorder, !slots.isEmpty else { return nil }
        var headingID: String? = nil
        for slot in slots {
            if slot.isHeading {
                if point.y < slot.frame.midY { return (slot.id, headingID, slot.frame.minY) }
                headingID = slot.id
                continue
            }
            if point.y < slot.frame.midY { return (slot.id, slot.headingID, slot.frame.minY) }
        }
        let last = slots.last!
        return (nil, last.isHeading ? last.id : last.headingID, last.frame.maxY)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if TaskDrag.read(sender.draggingPasteboard).isEmpty {
            guard onExternalDrop != nil, !Links.items(from: sender.draggingPasteboard).isEmpty else { return [] }
            let target = target(for: point)
            indicatorY = target?.y
            dropHeadingID = target?.headingID
            needsDisplay = true
            return .copy
        }
        guard let target = target(for: point) else {
            indicatorY = nil
            needsDisplay = true
            return []
        }
        indicatorY = target.y
        dropHeadingID = target.headingID
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        indicatorY = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicatorY = nil
        needsDisplay = true
        let ids = TaskDrag.read(sender.draggingPasteboard)
        let point = convert(sender.draggingLocation, from: nil)
        if ids.isEmpty {
            let items = Links.items(from: sender.draggingPasteboard)
            guard !items.isEmpty, let onExternalDrop else { return false }
            let target = target(for: point)
            onExternalDrop(items, target?.beforeID, target?.headingID)
            return true
        }
        guard let target = target(for: point) else { return false }
        onDrop?(ids, target.beforeID, target.headingID)
        return true
    }
}

/// Upcoming day header: big day number, weekday name, hairline to the right.
final class UpcomingDayHeader: FlippedView {
    private let number = NSTextField.label("", font: Fonts.bold(28), color: Theme.text)
    private let label = NSTextField.label("", font: Fonts.semibold(15), color: Theme.secondary)

    init(date: Date) {
        super.init(frame: .zero)
        number.stringValue = date.dayNumberString
        label.stringValue = date.isTomorrow ? "Tomorrow" : date.weekdayString
        addSubview(number)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let numberWidth = number.fittingWidth
        number.frame = NSRect(x: 0, y: 4, width: numberWidth, height: 34)
        label.frame = NSRect(x: numberWidth + 6, y: 15, width: label.fittingWidth + 4, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        let x = number.fittingWidth + 6
        NSRect(x: x, y: 13, width: bounds.width - x, height: 1).fill()
    }
}

/// Group header in Anytime / Someday / Logbook: the project (ring) or area (box) a run of to-dos belongs to.
final class GroupHeaderView: FlippedView {
    private let title = NSTextField.label("", font: Fonts.semibold(14.5), color: Theme.text)
    private let ring = ProgressRing()
    private let icon = NSImageView()
    private let isProject: Bool
    var onClick: (() -> Void)?

    init(title text: String, projectID: String?, color: NSColor) {
        isProject = projectID != nil
        super.init(frame: .zero)
        title.stringValue = text
        if let projectID {
            let progress = TaskStore.shared.projectProgress(projectID)
            ring.progress = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
            ring.color = color
            addSubview(ring)
        } else {
            icon.image = NSImage.symbol("shippingbox", size: 13, weight: .semibold, color: Theme.success)
            addSubview(icon)
        }
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        ring.frame = NSRect(x: -1, y: bounds.height - 26, width: 18, height: 18)
        icon.frame = NSRect(x: 0, y: bounds.height - 25, width: 16, height: 16)
        title.frame = NSRect(x: 24, y: bounds.height - 27, width: bounds.width - 24, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// "Show 25 more" link under a collapsed group.
final class ShowMoreView: FlippedView {
    private let button: FlatButton
    init(count: Int, action: @escaping () -> Void) {
        button = FlatButton(title: "Show \(count) more", symbol: nil, color: Theme.tertiary, fontSize: 13)
        super.init(frame: .zero)
        let target = CardTarget()
        target.handler = action
        objc_setAssociatedObject(button, "target", target, .OBJC_ASSOCIATION_RETAIN)
        button.target = target
        button.action = #selector(CardTarget.fire)
        button.alignment = .left
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        button.frame = NSRect(x: 0, y: 4, width: 200, height: 20)
    }
}

/// Big grey list icon shown in the middle of an empty list, as in Things.
final class BigEmptyIconView: FlippedView {
    private let icon = NSImageView()
    init(symbol: String) {
        super.init(frame: .zero)
        icon.image = NSImage.symbol(symbol, size: 72, weight: .regular, color: Theme.separator)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 96) / 2, y: (bounds.height - 96) / 2, width: 96, height: 96)
    }
}


/// A grey text link row ("Hide later items", "Show 3 later items").
final class LinkRowView: FlippedView {
    private let button: FlatButton
    private let target = CardTarget()
    init(title: String, action: @escaping () -> Void) {
        button = FlatButton(title: title, symbol: nil, color: Theme.tertiary, fontSize: 13)
        super.init(frame: .zero)
        target.handler = action
        button.target = target
        button.action = #selector(CardTarget.fire)
        button.alignment = .left
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        button.frame = NSRect(x: 0, y: 4, width: 240, height: 20)
    }
}

/// Things' tag filter: "All" plus one pill per tag used in the list.
final class TagFilterBar: FlippedView {
    private var buttons: [NSButton] = []
    private let onPick: (String?) -> Void
    private let targets: [CardTarget]

    init(tags: [String], selected: String?, onPick: @escaping (String?) -> Void) {
        self.onPick = onPick
        var targets: [CardTarget] = []
        var buttons: [NSButton] = []
        for value in [nil] + tags.map(Optional.some) {
            let button = PillButton(title: value ?? "All", selected: value == selected)
            let target = CardTarget()
            target.handler = { onPick(value) }
            button.target = target
            button.action = #selector(CardTarget.fire)
            targets.append(target)
            buttons.append(button)
        }
        let more = IconButton(symbol: "ellipsis", size: 13, color: Theme.secondary, tooltip: "Tags")
        let moreTarget = CardTarget()
        moreTarget.handler = { onPick(nil) }
        more.target = moreTarget
        more.action = #selector(CardTarget.fire)
        targets.append(moreTarget)
        buttons.append(more)
        self.targets = targets
        self.buttons = buttons
        super.init(frame: .zero)
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in buttons {
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: 3, width: width, height: 24)
            x += width + 8
        }
    }
}

private final class PillButton: NSButton {
    private let selectedPill: Bool
    init(title: String, selected: Bool) {
        selectedPill = selected
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        refusesFirstResponder = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Fonts.semibold(13), .foregroundColor: selectedPill ? Theme.text : Theme.secondary]
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: attributes).width) + 24, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        if selectedPill {
            Theme.secondary.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}


/// Things' yellow "You have N new to-dos  [OK]" banner at the top of Today.
final class NewTodosBanner: FlippedView {
    private let label = NSTextField.label("", font: Fonts.medium(14), color: Theme.listColor(.today))
    private let button = NSButton(title: "OK", target: nil, action: nil)
    private let target = CardTarget()

    private static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.98, green: 0.80, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.38, blue: 0.0, alpha: 1)
    }

    init(count: Int, onOK: @escaping () -> Void) {
        super.init(frame: .zero)
        let ink = Self.ink
        let text = NSMutableAttributedString(string: "You have ", attributes: [.font: Fonts.medium(14), .foregroundColor: ink])
        text.append(NSAttributedString(string: "\(count)", attributes: [.font: Fonts.bold(14), .foregroundColor: ink]))
        text.append(NSAttributedString(string: count == 1 ? " new to-do" : " new to-dos", attributes: [.font: Fonts.medium(14), .foregroundColor: ink]))
        label.attributedStringValue = text
        target.handler = onOK
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor(srgbRed: 0.98, green: 0.84, blue: 0.25, alpha: 1).cgColor
        button.attributedTitle = NSAttributedString(string: "OK", attributes: [.font: Fonts.bold(14), .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
        button.target = target
        button.action = #selector(CardTarget.fire)
        addSubview(label)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: (bounds.height - 20) / 2, width: bounds.width - 90, height: 20)
        button.frame = NSRect(x: bounds.width - 50, y: (bounds.height - 24) / 2, width: 44, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.listColor(.today).withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}


/// Things' calendar prompt at the top of Upcoming / Today.
final class CalendarPromptCard: FlippedView {
    private let label = NSTextField.wrappingLabel("This list is your schedule for the coming days. Would you like to display events from your calendar as well?",
                                                 font: Fonts.regular(13), color: Theme.secondary)
    private let noButton = NSButton(title: "No Thanks", target: nil, action: nil)
    private let yesButton = NSButton(title: "Show Events", target: nil, action: nil)
    private let noTarget = CardTarget(), yesTarget = CardTarget()

    init(onNo: @escaping () -> Void, onYes: @escaping () -> Void) {
        super.init(frame: .zero)
        label.alignment = .center
        noTarget.handler = onNo
        yesTarget.handler = onYes
        for (button, target) in [(noButton, noTarget), (yesButton, yesTarget)] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = NSColor(srgbRed: 0.27, green: 0.45, blue: 0.85, alpha: 1).cgColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: Fonts.medium(13), .foregroundColor: NSColor.white])
            button.target = target
            button.action = #selector(CardTarget.fire)
            addSubview(button)
        }
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 20, y: 12, width: bounds.width - 40, height: 36)
        let w: CGFloat = 110
        noButton.frame = NSRect(x: bounds.midX - w - 5, y: bounds.height - 34, width: w, height: 22)
        yesButton.frame = NSRect(x: bounds.midX + 5, y: bounds.height - 34, width: w, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.card.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
