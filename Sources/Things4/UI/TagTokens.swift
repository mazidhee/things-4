import AppKit

/// A filled tag token, as in Things 3's open to-do (green by default; tag colour if set).
final class TagToken: NSView {
    let tagName: String
    var onRemove: ((String) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(tag: String) {
        self.tagName = tag
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var font: NSFont { Fonts.semibold(13) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((tagName as NSString).size(withAttributes: [.font: font]).width) + 22 + (hovering ? 12 : 0), height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; superview?.needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovering = false; superview?.needsLayout = true }

    override func draw(_ dirtyRect: NSRect) {
        TaskStore.shared.tagColor(tagName).color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (tagName as NSString).size(withAttributes: attrs)
        (tagName as NSString).draw(at: NSPoint(x: 11, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        if hovering, let x = NSImage.symbol("xmark", size: 8, weight: .bold, color: NSColor.white.withAlphaComponent(0.85)) {
            x.draw(in: NSRect(x: bounds.width - 17, y: (bounds.height - 9) / 2, width: 9, height: 9))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if hovering, convert(event.locationInWindow, from: nil).x > bounds.width - 20 { onRemove?(tagName); return }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(TagMenus.colorMenu(for: tagName), with: event, for: self)
    }
}

enum TagMenus {
    /// "Color" choices for a tag, with a swatch per colour.
    static func colorMenu(for tag: String) -> NSMenu {
        let menu = NSMenu()
        let current = TaskStore.shared.tagColor(tag)
        for color in TagColor.allCases {
            let item = ClosureMenuItem(color == .none ? "Default (Green)" : color.title, checked: color == current) {
                TaskStore.shared.setTagColor(tag, color)
            }
            item.image = swatch(color.color)
            menu.addItem(item)
        }
        return menu
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
