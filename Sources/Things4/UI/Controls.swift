import AppKit

/// The round task checkbox. ⌥-click cancels instead of completing, as in Things.
final class CheckboxView: NSView {
    var isChecked = false {
        didSet { needsDisplay = true }
    }
    var isCanceled = false {
        didSet { needsDisplay = true }
    }
    var tint: NSColor = Theme.accent {
        didSet { needsDisplay = true }
    }
    /// Things to-dos use a rounded square; checklist items keep the circle.
    var isSquare = false {
        didSet { needsDisplay = true }
    }
    /// Called with `true` when the click carried the Option key.
    var onToggle: ((Bool) -> Void)?

    private var hovering = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        onToggle?(event.modifierFlags.contains(.option))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = isSquare ? bounds.insetBy(dx: 1, dy: 1) : bounds.insetBy(dx: 2, dy: 2)
        let path = isSquare ? NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5) : NSBezierPath(ovalIn: rect)

        if isChecked {
            tint.setFill()
            path.fill()
            let mark = NSBezierPath()
            if isCanceled {
                let inset = rect.width * 0.3
                mark.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
                mark.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
                mark.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
                mark.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
            } else {
                let x = rect.minX + rect.width * 0.26
                let y = rect.minY + rect.height * 0.52
                mark.move(to: NSPoint(x: x, y: y))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: y + rect.height * 0.18))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.30))
            }
            mark.lineWidth = 1.8
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            NSColor.white.setStroke()
            mark.stroke()
        } else {
            let stroke = hovering ? Theme.secondary : Theme.checkboxStroke
            stroke.setStroke()
            path.lineWidth = isSquare ? 1.2 : 1.4
            path.stroke()
            if hovering {
                tint.withAlphaComponent(0.12).setFill()
                path.fill()
            }
        }
    }
}

/// A clickable text button with no bezel, used in headers.
final class FlatButton: NSButton {
    init(title: String, symbol: String? = nil, color: NSColor = Theme.secondary, fontSize: CGFloat = 12) {
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.font = Fonts.medium(fontSize)
        self.contentTintColor = color
        self.imagePosition = symbol == nil ? .noImage : .imageLeading
        if let symbol { self.image = NSImage.symbol(symbol, size: fontSize, weight: .medium, color: color) }
        self.setButtonType(.momentaryChange)
        self.refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class IconButton: NSButton {
    init(symbol: String, size: CGFloat = 15, color: NSColor = Theme.secondary, tooltip: String? = nil) {
        super.init(frame: .zero)
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.image = NSImage.symbol(symbol, size: size, weight: .medium, color: color)
        self.contentTintColor = color
        self.imagePosition = .imageOnly
        self.setButtonType(.momentaryChange)
        self.toolTip = tooltip
        self.refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A small rounded tag chip.
final class TagChip: NSView {
    /// Things draws row tags as outlined pills.
    var isOutlined = false { didSet { needsDisplay = true } }
    /// Things' project count is a small square box, not a pill.
    var isSquare = false { didSet { needsDisplay = true } }
    /// Optional tag colour: tints the outline and text (rows) or fills the pill.
    var tint: NSColor? { didSet { needsDisplay = true } }
    var text: String {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var onClick: ((String) -> Void)?

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: Fonts.regular(10.5)]).width + (isSquare ? 8 : (isOutlined ? 16 : 12))
        return NSSize(width: max(18, width), height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(text)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOutlined {
            let radius = isSquare ? 3 : bounds.height / 2
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            if let tint {
                tint.withAlphaComponent(0.14).setFill()
                path.fill()
            }
            (tint ?? Theme.tertiary).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
            Theme.tagBackground.setFill()
            path.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: tint == nil ? Fonts.regular(10.5) : Fonts.medium(10.5),
            .foregroundColor: tint ?? Theme.tagText
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}

/// Ring that shows a project's completion. Click it to complete the project.
final class ProgressRing: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }
    var color: NSColor = Theme.accent {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?
    var lineWidth: CGFloat = 1.6 { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let background = NSBezierPath(ovalIn: rect)
        color.setStroke()
        background.lineWidth = lineWidth
        background.stroke()

        guard progress > 0 else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: rect.midY))
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                       radius: rect.width / 2 - 1.5,
                       startAngle: 90,
                       endAngle: 90 - 360 * progress,
                       clockwise: true)
        path.close()
        color.setFill()
        path.fill()
    }
}

final class SeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        bounds.fill()
    }
}

/// A horizontal bar that keeps its height while hosting a stack of controls.
final class HeaderBar: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 52) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.window.setFill()
        bounds.fill()
    }
}

/// A menu item that runs a closure. Keeps the context-menu code short.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [],
         checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        state = checked ? .on : .off
        if let symbol {
            image = NSImage.symbol(symbol, size: 12, weight: .regular, color: Theme.secondary)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
