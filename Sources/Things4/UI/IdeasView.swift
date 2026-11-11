import AppKit

// MARK: - Icons

enum IdeaIcons {
    /// Raw is a dashed ring, Researching half full, Ready a solid dot in a ring.
    static func stageImage(_ stage: IdeaStage, size: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let color = Theme.ideaStageColor(stage)
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 1.3
            if stage == .raw { ring.setLineDash([2.2, 2.2], count: 2, phase: 0) }
            color.setStroke()
            ring.stroke()
            let inner = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.22)
            color.setFill()
            switch stage {
            case .raw: break
            case .researching:
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: inner).addClip()
                NSRect(x: inner.minX, y: inner.minY, width: inner.width / 2, height: inner.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            case .ready:
                NSBezierPath(ovalIn: inner).fill()
            }
            return true
        }
    }
}

// MARK: - Actions

enum IdeaActions {
    private static var store: TaskStore { TaskStore.shared }

    /// Promotes the idea and shows the new project.
    static func start(_ id: String, now: Bool) {
        guard let project = store.promoteIdea(id, startNow: now) else { return }
        // Changing the selection also closes the idea's page.
        (MainWindowController.active ?? .shared).state.selection = .project(project.id)
    }

    static func copyPrompt(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.ideaPrompt(id), forType: .string)
    }

    static func stageMenu(for id: String) -> NSMenu {
        let menu = NSMenu()
        guard let idea = store.task(id) else { return menu }
        for stage in IdeaStage.allCases {
            let item = ClosureMenuItem(stage.title, checked: idea.ideaStage == stage) { store.setIdeaStage(id, stage) }
            item.image = IdeaIcons.stageImage(stage)
            menu.addItem(item)
        }
        return menu
    }

    static func areaMenu(for id: String) -> NSMenu {
        let menu = NSMenu()
        guard let idea = store.task(id) else { return menu }
        func set(_ areaID: String?) {
            guard var fresh = store.task(id) else { return }
            fresh.areaID = areaID
            store.update(fresh)
        }
        menu.addItem(ClosureMenuItem("No Area", checked: idea.areaID == nil) { set(nil) })
        if !store.areas.isEmpty { menu.addItem(.separator()) }
        for area in store.areas.sorted(by: { $0.index < $1.index }) {
            menu.addItem(ClosureMenuItem(area.title, symbol: "things.area.plain", checked: idea.areaID == area.id) { set(area.id) })
        }
        return menu
    }

    static func contextMenu(for id: String, open: (() -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        if let open {
            menu.addItem(ClosureMenuItem("Open", symbol: "doc.text", handler: open))
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Start Now", symbol: "play.fill") { start(id, now: true) })
        menu.addItem(ClosureMenuItem("Save for Someday", symbol: "archivebox") { start(id, now: false) })
        menu.addItem(.separator())
        let stage = NSMenuItem(title: "Stage", action: nil, keyEquivalent: "")
        stage.submenu = stageMenu(for: id)
        menu.addItem(stage)
        let area = NSMenuItem(title: "Area", action: nil, keyEquivalent: "")
        area.submenu = areaMenu(for: id)
        menu.addItem(area)
        menu.addItem(ClosureMenuItem("Copy as Prompt for Claude", symbol: "doc.on.doc") { copyPrompt(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete", symbol: "trash") { store.moveToTrash(id) })
        return menu
    }
}

// MARK: - Row

/// An idea in the Ideas list: bulb, title, its one-line pitch, and on the right
/// the steps it already has, its area and when it was last touched.
final class IdeaRowView: HoverRowView {
    override var isFlipped: Bool { true }
    let idea: TaskItem
    var isSelectedRow = false { didSet { needsDisplay = true } }
    var onSelect: ((TaskItem, NSEvent) -> Void)?
    var onOpen: ((TaskItem) -> Void)?
    var onContextMenu: ((TaskItem, NSEvent) -> Void)?

    static var height: CGFloat { ceil(50 * Fonts.scale) }

    private let pitch: String
    private let steps: Int
    private let areaTitle: String?

    init(idea: TaskItem) {
        self.idea = idea
        pitch = idea.pitch
        steps = TaskStore.extractSteps(from: idea.notes).steps.count
        areaTitle = idea.areaID.flatMap { TaskStore.shared.area($0)?.title }
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func edited(_ date: Date) -> String {
        if date.isToday { return "Today" }
        let days = Calendar.current.dateComponents([.day], from: date.startOfDay, to: Date().startOfDay).day ?? 0
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        return date.monthDayString
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = bounds.insetBy(dx: -6, dy: 1)
        if isSelectedRow {
            Theme.rowSelection.setFill()
            NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        } else if isHovered {
            Theme.rowHover.setFill()
            NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        }

        let scale = Fonts.scale
        let titleY = 6 * scale
        // The bulb sits where a to-do's checkbox would, centred on the title line.
        NSImage.symbol("lightbulb.fill", size: 11, weight: .medium, color: Theme.idea)?
            .draw(in: NSRect(x: 0, y: titleY + 1.5 * scale, width: 14, height: 15), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)

        // Right-hand details, laid out from the right edge on the title's baseline.
        let metaFont = Fonts.regular(12)
        var right = bounds.width
        func drawRight(_ text: String, color: NSColor, image: NSImage? = nil) {
            let attributes: [NSAttributedString.Key: Any] = [.font: metaFont, .foregroundColor: color]
            let width = ceil((text as NSString).size(withAttributes: attributes).width)
            right -= width
            (text as NSString).draw(at: NSPoint(x: right, y: titleY + 1.5 * scale), withAttributes: attributes)
            if let image {
                right -= 15
                image.draw(in: NSRect(x: right, y: titleY + 3 * scale, width: 11, height: 11), from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
            }
            right -= 14
        }
        drawRight(Self.edited(idea.modifiedAt), color: Theme.tertiary)
        if let areaTitle { drawRight(areaTitle, color: Theme.secondary, image: NSImage.symbol("things.area.plain", size: 9, color: Theme.tertiary)) }
        if steps > 0 {
            drawRight("\(steps) step\(steps == 1 ? "" : "s")", color: Theme.secondary,
                      image: NSImage.symbol("checklist", size: 9, weight: .regular, color: Theme.tertiary))
        }

        let textX: CGFloat = 21
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let untitled = idea.title.trimmingCharacters(in: .whitespaces).isEmpty
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: Fonts.medium(14), .foregroundColor: untitled ? Theme.tertiary : Theme.text,
                                                              .paragraphStyle: paragraph]
        let titleWidth = max(60, right - textX + 4)
        ((untitled ? "New Idea" : idea.title) as NSString)
            .draw(with: NSRect(x: textX, y: titleY, width: titleWidth, height: 19 * scale),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttributes)

        let pitchAttributes: [NSAttributedString.Key: Any] = [.font: Fonts.regular(12.5),
                                                              .foregroundColor: pitch.isEmpty ? Theme.placeholder : Theme.secondary,
                                                              .paragraphStyle: paragraph]
        let plain = pitch.isEmpty ? "No notes yet" : Markdown.plainPreview(pitch)
        (plain as NSString).draw(with: NSRect(x: textX, y: titleY + 21 * scale, width: bounds.width - textX - 4, height: 17 * scale),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: pitchAttributes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onOpen?(idea); return }
        onSelect?(idea, event)
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(idea, event) }
}

// MARK: - Promote bar

/// A rounded text button: filled for the main action, outlined otherwise.
final class PillActionButton: NSButton {
    private let filled: Bool
    private let symbol: String?
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String? = nil, filled: Bool) {
        self.filled = filled
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    private var font13: NSFont { Fonts.medium(13) }

    override var intrinsicContentSize: NSSize {
        let text = ceil((title as NSString).size(withAttributes: [.font: font13]).width)
        return NSSize(width: text + (symbol == nil ? 0 : 17) + 26, height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let pressed = isHighlighted
        if filled {
            Theme.accent.withAlphaComponent(pressed ? 0.8 : (hovering ? 0.92 : 1)).setFill()
            path.fill()
        } else {
            (hovering || pressed ? Theme.rowHover : Theme.window).setFill()
            path.fill()
            Theme.boardCardBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor = filled ? .white : Theme.text
        var x: CGFloat = 13
        if let symbol {
            NSImage.symbol(symbol, size: 10.5, weight: .semibold, color: color)?
                .draw(in: NSRect(x: x, y: bounds.midY - 6.5, width: 13, height: 13), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            x += 17
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font13, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: x, y: floor(bounds.midY - size.height / 2)), withAttributes: attributes)
    }
}

/// Under an idea's properties: start it now, park it in Someday, or take it to Claude.
final class IdeaPromoteBar: FlippedView {
    private let startButton = PillActionButton(title: "Start Now", symbol: "play.fill", filled: true)
    private let somedayButton = PillActionButton(title: "Save for Someday", filled: false)
    private let copyButton = FlatButton(title: "Copy as Prompt for Claude", symbol: "doc.on.doc", color: Theme.secondary, fontSize: 12.5)
    private let hint = NSTextField.label("", font: Fonts.regular(12), color: Theme.tertiary)
    private let ideaID: String
    private var copiedTimer: Timer?

    init(ideaID: String) {
        self.ideaID = ideaID
        super.init(frame: .zero)
        startButton.target = self
        startButton.action = #selector(startNow)
        startButton.toolTip = "Make this a project and plan its first step for today"
        somedayButton.target = self
        somedayButton.action = #selector(startSomeday)
        somedayButton.toolTip = "Make this a project in Someday"
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        copyButton.toolTip = "Copies the idea and your notes, ready to paste into Claude"
        let steps = TaskStore.extractSteps(from: TaskStore.shared.task(ideaID)?.notes ?? "").steps.count
        hint.stringValue = steps == 0 ? "Checkboxes in your notes become the project's to-dos."
            : "\(steps) checkbox\(steps == 1 ? "" : "es") in your notes will become to-dos."
        hint.lineBreakMode = .byTruncatingTail
        [startButton, somedayButton, copyButton, hint].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static let height: CGFloat = 58

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in [startButton, somedayButton] {
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: 0, width: width, height: 28)
            x += width + 8
        }
        // The copy action sits on the right; in a narrow window it shrinks to its icon.
        copyButton.imagePosition = .imageLeading
        var copyWidth = ceil(copyButton.intrinsicContentSize.width)
        if x + 16 + copyWidth > bounds.width {
            copyButton.imagePosition = .imageOnly
            copyWidth = 28
        }
        copyButton.frame = NSRect(x: bounds.width - copyWidth, y: 2, width: copyWidth, height: 24)
        hint.frame = NSRect(x: 1, y: 38, width: bounds.width - 2, height: 16)
    }

    @objc private func startNow() { IdeaActions.start(ideaID, now: true) }
    @objc private func startSomeday() { IdeaActions.start(ideaID, now: false) }

    @objc private func copy(_ sender: Any?) {
        IdeaActions.copyPrompt(ideaID)
        copyButton.title = "Copied"
        copyButton.image = NSImage.symbol("checkmark", size: 12.5, weight: .medium, color: Theme.success)
        needsLayout = true
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.copyButton.title = "Copy as Prompt for Claude"
            self.copyButton.image = NSImage.symbol("doc.on.doc", size: 12.5, weight: .medium, color: Theme.secondary)
            self.needsLayout = true
        }
    }
}
