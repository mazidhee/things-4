import AppKit

/// Full-bleed Notion-style cover at the top of Today. Hover shows Change cover /
/// Reposition / Remove; Reposition lets the image be dragged vertically.
final class CoverView: NSView {
    var spec: String { didSet { if spec != oldValue { loadImage() } } }
    var offset: CGFloat { didSet { needsDisplay = true } }
    var onChange: ((String?) -> Void)?
    var onOffset: ((CGFloat) -> Void)?

    private var image: NSImage?
    private let controls = CoverControls()
    private let hint = CoverControls()
    private var hovering = false
    private var repositioning = false
    private var savedOffset: CGFloat = 0.5
    private var dragStart: (y: CGFloat, offset: CGFloat)?
    private var popover: NSPopover?

    init(spec: String, offset: CGFloat) {
        self.spec = spec
        self.offset = offset
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        addSubview(controls)
        addSubview(hint)
        hint.setItems([("Drag image to reposition", nil)])
        hint.isHidden = true
        configureControls()
        loadImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var isImage: Bool { Covers.fileURL(for: spec) != nil }

    private func loadImage() {
        image = Covers.cachedImage(spec)
        needsDisplay = true
        guard image == nil, isImage else { configureControls(); return }
        let requested = spec
        Covers.loadImage(spec) { [weak self] loaded in
            guard let self, self.spec == requested else { return }
            self.image = loaded
            self.needsDisplay = true
        }
        configureControls()
    }

    private func configureControls() {
        if repositioning {
            controls.setItems([("Save position", #selector(savePosition)), ("Cancel", #selector(cancelReposition))], target: self)
        } else if isImage {
            controls.setItems([("Change cover", #selector(changeCover)), ("Reposition", #selector(startReposition)), ("Remove", #selector(removeCover))], target: self)
        } else {
            controls.setItems([("Change cover", #selector(changeCover)), ("Remove", #selector(removeCover))], target: self)
        }
        updateVisibility()
        needsLayout = true
    }

    private func updateVisibility() {
        controls.isHidden = !(hovering || repositioning || popover?.isShown == true)
        hint.isHidden = !repositioning
    }

    override func layout() {
        super.layout()
        let size = controls.fittingSize
        controls.frame = NSRect(x: bounds.width - size.width - Layout.column(in: bounds.width).x + 8,
                                y: bounds.height - size.height - 14, width: size.width, height: size.height)
        let hintSize = hint.fittingSize
        hint.frame = NSRect(x: (bounds.width - hintSize.width) / 2, y: (bounds.height - hintSize.height) / 2,
                            width: hintSize.width, height: hintSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        bounds.clip()
        if let image {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: -(size.height - bounds.height) * offset,
                              width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if !Covers.drawGenerated(spec, in: bounds) {
            Theme.separator.setFill()
            bounds.fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateVisibility() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateVisibility() }

    override func resetCursorRects() {
        if repositioning { addCursorRect(bounds, cursor: .openHand) }
    }

    // MARK: Reposition

    override func mouseDown(with event: NSEvent) {
        guard repositioning else { return }
        dragStart = (convert(event.locationInWindow, from: nil).y, offset)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard repositioning, let dragStart, let image else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let overflow = image.size.height * scale - bounds.height
        guard overflow > 1 else { return }
        let dy = convert(event.locationInWindow, from: nil).y - dragStart.y
        offset = min(1, max(0, dragStart.offset - dy / overflow))
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }

    @objc private func startReposition() {
        savedOffset = offset
        repositioning = true
        configureControls()
        window?.invalidateCursorRects(for: self)
    }

    @objc private func savePosition() {
        repositioning = false
        configureControls()
        window?.invalidateCursorRects(for: self)
        onOffset?(offset)
    }

    @objc private func cancelReposition() {
        offset = savedOffset
        repositioning = false
        configureControls()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Actions

    @objc private func removeCover() { onChange?(nil) }

    @objc private func changeCover() {
        let gallery = CoverGalleryViewController(current: spec) { [weak self] choice in
            self?.popover?.close()
            self?.onChange?(choice)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = gallery
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: controls.bounds, of: controls, preferredEdge: .maxY)
    }

    // MARK: Drop an image file

    private func droppedImage(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL]
        return urls?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedImage(sender) == nil ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedImage(sender), let spec = Covers.importImage(at: url) else { return false }
        onChange?(spec)
        return true
    }
}

extension CoverView: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        updateVisibility()
    }
}

/// Notion's joined pill of text buttons on the cover.
final class CoverControls: NSView {
    private var buttons: [NSButton] = []

    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 0.92) : NSColor(white: 1, alpha: 0.92)
    }
    private static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.82) : NSColor(white: 0.2, alpha: 1)
    }

    func setItems(_ items: [(String, Selector?)], target: AnyObject? = nil) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.map { title, action in
            let button = NSButton(title: title, target: target, action: action)
            button.isBordered = false
            button.refusesFirstResponder = true
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: Fonts.medium(12), .foregroundColor: Self.ink])
            button.isEnabled = action != nil
            addSubview(button)
            return button
        }
        needsLayout = true
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        let widths = buttons.map { ceil($0.attributedTitle.size().width) + 20 }
        return NSSize(width: widths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)), height: 26)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in buttons {
            let width = ceil(button.attributedTitle.size().width) + 20
            button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        Self.ink.withAlphaComponent(0.15).setFill()
        for button in buttons.dropLast() {
            NSRect(x: button.frame.maxX, y: 5, width: 1, height: bounds.height - 10).fill()
        }
    }
}

/// "Add Cover", shown at the right of the Today title while hovering it.
final class AddCoverReveal: NSView {
    private let button = FlatButton(title: "Add Cover", symbol: "photo", color: Theme.secondary, fontSize: 12)
    var onAdd: (() -> Void)?
    /// Space kept free at the right edge for the header's own button.
    var trailingInset: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        button.target = self
        button.action = #selector(add)
        button.alphaValue = ProcessInfo.processInfo.environment["THINGS4_SNAP_HOVER"] == "cover" ? 1 : 0
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // This view is not flipped: measure from the top so it lines up with the header's own button.
        let width = ceil(button.intrinsicContentSize.width)
        button.frame = NSRect(x: bounds.width - width - (trailingInset > 0 ? trailingInset + 18 : 0), y: bounds.height - 13 - 24, width: width, height: 24)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return button.alphaValue > 0 && button.frame.contains(local) ? button : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { button.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { button.animator().alphaValue = 0 }

    @objc private func add() { onAdd?() }
}

/// Gallery popover: Upload / Remove, colours and gradients, macOS wallpapers.
final class CoverGalleryViewController: NSViewController {
    private let current: String?
    private let onPick: (String?) -> Void
    private let width: CGFloat = 520

    init(current: String?, onPick: @escaping (String?) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 440))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 396))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let content = FlippedView(frame: .zero)
        scroll.documentView = content

        let title = NSTextField.label("Gallery", font: Fonts.semibold(13), color: Theme.text)
        title.frame = NSRect(x: 16, y: 410, width: 120, height: 18)
        let upload = FlatButton(title: "Upload…", symbol: "square.and.arrow.up", color: Theme.accent, fontSize: 12)
        upload.target = self
        upload.action = #selector(uploadImage)
        let remove = FlatButton(title: "Remove", color: Theme.secondary, fontSize: 12)
        remove.target = self
        remove.action = #selector(removeCover)
        remove.isHidden = current == nil
        remove.frame = NSRect(x: width - 76, y: 406, width: 64, height: 24)
        upload.frame = NSRect(x: width - (current == nil ? 92 : 168), y: 406, width: 84, height: 24)
        let line = NSBox(frame: NSRect(x: 0, y: 396, width: width, height: 1))
        line.boxType = .separator
        [scroll, title, upload, remove, line].forEach(root.addSubview)

        var y: CGFloat = 12
        func section(_ name: String) {
            let label = NSTextField.label(name.uppercased(), font: Fonts.semibold(10.5), color: Theme.secondary)
            label.frame = NSRect(x: 16, y: y, width: 300, height: 14)
            content.addSubview(label)
            y += 22
        }
        let columns = 4, gap: CGFloat = 8
        let tileW = floor((width - 32 - gap * CGFloat(columns - 1)) / CGFloat(columns)), tileH: CGFloat = 64
        func grid(_ specs: [String]) {
            for (i, spec) in specs.enumerated() {
                let tile = CoverTile(spec: spec, selected: spec == current)
                tile.frame = NSRect(x: 16 + CGFloat(i % columns) * (tileW + gap), y: y + CGFloat(i / columns) * (tileH + gap), width: tileW, height: tileH)
                tile.onClick = { [weak self] in self?.onPick(spec) }
                content.addSubview(tile)
            }
            y += CGFloat((specs.count + columns - 1) / columns) * (tileH + gap) + 14
        }
        section("Gradients")
        grid(Covers.gradients.indices.map { "gradient:\($0)" })
        section("Colors")
        grid(Covers.colors.indices.map { "color:\($0)" })
        let wallpapers = Covers.wallpapers
        if !wallpapers.isEmpty {
            section("macOS Wallpapers")
            grid(wallpapers.map { "wallpaper:" + $0.path })
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: y)
        view = root
    }

    @objc private func uploadImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a cover image for Today"
        guard panel.runModal() == .OK, let url = panel.url, let spec = Covers.importImage(at: url) else { return }
        onPick(spec)
    }

    @objc private func removeCover() { onPick(nil) }
}

private final class CoverTile: NSView {
    let spec: String
    let selected: Bool
    var onClick: (() -> Void)?
    private var image: NSImage?
    private var hovering = false

    init(spec: String, selected: Bool) {
        self.spec = spec
        self.selected = selected
        super.init(frame: .zero)
        if Covers.fileURL(for: spec) != nil {
            Covers.loadImage(spec, maxPixel: 360) { [weak self] image in
                self?.image = image
                self?.needsDisplay = true
            }
        }
        toolTip = spec.hasPrefix("wallpaper:") ? (spec as NSString).lastPathComponent.replacingOccurrences(of: ".heic", with: "") : nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        if let image {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if !Covers.drawGenerated(spec, in: bounds) {
            Theme.separator.setFill()
            bounds.fill()
        }
        if hovering { NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill() }
        NSGraphicsContext.current?.restoreGraphicsState()
        if selected {
            Theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func mouseDown(with event: NSEvent) {}
}
