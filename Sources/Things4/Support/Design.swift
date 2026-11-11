import AppKit

/// Every colour is dynamic: it resolves against the current appearance at draw
/// time, so the whole app follows Light, Dark or System from Settings.
enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? DarkTheme.current.adapt(dark) : light
        }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // Surfaces
    static let window = dynamic(.white, rgb(0.157, 0.157, 0.163))
    static let sidebar = dynamic(rgb(0.957, 0.957, 0.965), rgb(0.145, 0.145, 0.15))
    static let sidebarSelection = dynamic(rgb(0.867, 0.867, 0.882), rgb(0.235, 0.235, 0.255))
    static let sidebarHover = dynamic(rgb(0.918, 0.918, 0.929, 0.7), rgb(0.2, 0.2, 0.215, 0.7))
    static let rowHover = dynamic(rgb(0.965, 0.965, 0.969), rgb(0.15, 0.15, 0.16))
    static let rowSelection = dynamic(rgb(0.80, 0.87, 0.98), rgb(0.18, 0.25, 0.44))
    static let separator = dynamic(rgb(0.886, 0.886, 0.898), rgb(0.22, 0.22, 0.235))
    /// Dividers inside the raised to-do card (checklist lines), a step stronger than `separator`.
    static let cardSeparator = dynamic(rgb(0.86, 0.86, 0.88), rgb(0.32, 0.32, 0.34))
    static let card = dynamic(rgb(0.973, 0.973, 0.976), rgb(0.16, 0.16, 0.172))
    static let cardElevated = dynamic(.white, rgb(0.205, 0.205, 0.21))
    static let panel = dynamic(rgb(0.980, 0.980, 0.984), rgb(0.13, 0.13, 0.14))
    static let toolbar = dynamic(.white, rgb(0.157, 0.157, 0.163))
    static let checkboxStroke = dynamic(rgb(0.72, 0.72, 0.75), rgb(0.42, 0.42, 0.45))
    static let ringTrack = dynamic(rgb(0.85, 0.85, 0.87), rgb(0.3, 0.3, 0.32))
    static let dropIndicator = dynamic(rgb(0.294, 0.620, 0.910), rgb(0.40, 0.68, 0.95))

    // Text
    static let text = dynamic(rgb(0.118, 0.118, 0.129), rgb(0.92, 0.92, 0.93))
    static let secondary = dynamic(rgb(0.529, 0.529, 0.553), rgb(0.62, 0.62, 0.65))
    static let tertiary = dynamic(rgb(0.678, 0.678, 0.702), rgb(0.5, 0.5, 0.53))
    static let placeholder = dynamic(rgb(0.741, 0.741, 0.761), rgb(0.42, 0.42, 0.45))
    static let strikethrough = dynamic(rgb(0.70, 0.70, 0.72), rgb(0.45, 0.45, 0.48))

    // Accents
    static let accent = dynamic(rgb(0.294, 0.620, 0.910), rgb(0.40, 0.68, 0.95))
    static let deadline = dynamic(rgb(0.85, 0.21, 0.30), rgb(0.89, 0.27, 0.36))
    static let evening = dynamic(rgb(0.33, 0.40, 0.70), rgb(0.58, 0.63, 0.90))
    static let success = dynamic(rgb(0.20, 0.62, 0.38), rgb(0.35, 0.75, 0.50))
    static let tagBackground = dynamic(rgb(0.933, 0.933, 0.945), rgb(0.22, 0.22, 0.24))
    static let tagText = dynamic(rgb(0.404, 0.404, 0.431), rgb(0.72, 0.72, 0.75))

    static func listColor(_ list: BuiltinList) -> NSColor {
        switch list {
        case .inbox: return dynamic(rgb(0.322, 0.624, 0.918), rgb(0.42, 0.70, 0.96))
        case .today: return dynamic(rgb(0.961, 0.706, 0.204), rgb(0.98, 0.76, 0.30))
        case .upcoming: return dynamic(rgb(0.918, 0.404, 0.318), rgb(0.95, 0.50, 0.42))
        case .anytime: return dynamic(rgb(0.298, 0.702, 0.522), rgb(0.40, 0.78, 0.60))
        case .someday: return dynamic(rgb(0.749, 0.569, 0.396), rgb(0.82, 0.66, 0.48))
        case .logbook: return dynamic(rgb(0.451, 0.741, 0.490), rgb(0.55, 0.80, 0.58))
        case .trash: return dynamic(rgb(0.612, 0.612, 0.639), rgb(0.55, 0.55, 0.58))
        case .active: return flowColor(.progress)
        case .ideas: return idea
        }
    }

    static func flowColor(_ flow: Flow) -> NSColor {
        switch flow {
        case .backlog: return dynamic(rgb(0.70, 0.72, 0.76), rgb(0.42, 0.43, 0.47))
        case .todo: return checkboxStroke
        case .progress: return dynamic(rgb(0.93, 0.62, 0.07), rgb(0.95, 0.72, 0.25))
        case .waiting: return dynamic(rgb(0.58, 0.40, 0.92), rgb(0.68, 0.56, 0.96))
        case .done: return accent
        case .canceled: return dynamic(rgb(0.70, 0.72, 0.76), rgb(0.42, 0.43, 0.47))
        }
    }

    /// Ideas: a soft rose, apart from Today's yellow and Waiting's purple.
    static let idea = dynamic(rgb(0.89, 0.40, 0.58), rgb(0.95, 0.52, 0.68))
    static func ideaStageColor(_ stage: IdeaStage) -> NSColor {
        switch stage {
        case .raw: return flowColor(.backlog)
        case .researching: return dynamic(rgb(0.30, 0.56, 0.90), rgb(0.45, 0.68, 0.98))
        case .ready: return success
        }
    }

    static let urgent = dynamic(rgb(0.94, 0.38, 0.18), rgb(0.96, 0.47, 0.25))
    static let boardCard = dynamic(.white, rgb(0.19, 0.19, 0.20))
    static let boardCardBorder = dynamic(rgb(0.90, 0.91, 0.93), rgb(0.27, 0.27, 0.29))

    static let projectColors: [NSColor] = [
        dynamic(rgb(0.322, 0.624, 0.918), rgb(0.42, 0.70, 0.96)),
        dynamic(rgb(0.918, 0.404, 0.318), rgb(0.95, 0.50, 0.42)),
        dynamic(rgb(0.298, 0.702, 0.522), rgb(0.40, 0.78, 0.60)),
        dynamic(rgb(0.663, 0.478, 0.851), rgb(0.74, 0.58, 0.92)),
        dynamic(rgb(0.949, 0.620, 0.239), rgb(0.97, 0.70, 0.36)),
        dynamic(rgb(0.396, 0.651, 0.749), rgb(0.50, 0.74, 0.84))
    ]

    static func projectColor(for id: String) -> NSColor {
        var hash = 5381
        for scalar in id.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return projectColors[abs(hash) % projectColors.count]
    }
}

/// All interface text goes through here so Settings › Text Size scales everything.
enum Fonts {
    static var scale: CGFloat { Preferences.textScale }
    static func regular(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size * scale) }
    static func medium(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size * scale, weight: .medium) }
    static func semibold(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size * scale, weight: .semibold) }
    static func bold(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size * scale, weight: .bold) }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

extension NSColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        if value.count == 6 { number = number << 8 | 0xFF }
        self.init(srgbRed: CGFloat((number & 0xFF000000) >> 24) / 255,
                  green: CGFloat((number & 0x00FF0000) >> 16) / 255,
                  blue: CGFloat((number & 0x0000FF00) >> 8) / 255,
                  alpha: CGFloat(number & 0x000000FF) / 255)
    }
}

extension NSView {
    func removeAllSubviews() {
        subviews.forEach { $0.removeFromSuperview() }
    }

    func addSubviewPinned(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

extension NSTextField {
    static func label(_ text: String, font: NSFont, color: NSColor = Theme.text) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    static func wrappingLabel(_ text: String, font: NSFont, color: NSColor = Theme.text) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.isEditable = false
        field.drawsBackground = false
        field.isBezeled = false
        return field
    }

    /// Width of the current text in the current font, independent of the frame.
    var fittingWidth: CGFloat {
        let text = attributedStringValue.length > 0 ? attributedStringValue.string : stringValue
        return ceil((text as NSString).size(withAttributes: [.font: font ?? Fonts.regular(12)]).width) + 4
    }

    /// Plain editable field with no bezel, used inside cards and rows.
    static func inlineField(placeholder: String, font: NSFont) -> NSTextField {
        let field = NSTextField()
        field.font = font
        field.textColor = Theme.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        return field
    }
}

extension NSImage {
    /// Symbol names that are drawn with Things 3's own artwork when it is bundled
    /// (Resources/ThingsIcons); otherwise the SF Symbol is used.
    private static let thingsArtwork: [String: String] = [
        "things.inbox": "Inbox", "tray": "Inbox", "tray.fill": "Inbox",
        "things.today": "Today", "star.fill": "Today",
        "things.upcoming": "Upcoming",
        "things.anytime": "Anytime", "square.stack.3d.up.fill": "Anytime",
        "things.someday": "Someday", "archivebox.fill": "Someday",
        "things.logbook": "Logbook", "checkmark.circle.fill": "Logbook",
        "things.area": "Area", "shippingbox": "Area",
        "things.evening": "Evening", "moon.fill": "Evening",
        "things.project": "Project", "circle.lefthalf.filled": "Project",
        "things.deadline": "Deadlines",
        "things.repeat": "Repeating",
        "things.tag": "Tag"
    ]
    private static var artworkCache: [String: NSImage] = [:]

    static func thingsArtwork(for name: String, size: CGFloat) -> NSImage? {
        guard let file = thingsArtwork[name],
              let dir = Bundle.main.resourceURL?.appendingPathComponent("ThingsIcons") else { return nil }
        let key = "\(file)@\(size)"
        if let cached = artworkCache[key] { return cached }
        guard let light = NSImage(contentsOf: dir.appendingPathComponent(file + ".png")) else { return nil }
        let dark = NSImage(contentsOf: dir.appendingPathComponent(file + "-dark.png")) ?? light
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
        artworkCache[key] = image
        return image
    }

    /// A tinted SF Symbol. The tint is applied inside a drawing handler so a
    /// dynamic colour resolves correctly whenever the image is drawn.
    static func symbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .medium, color: NSColor = Theme.text) -> NSImage? {
        if name == "workflow.active" { return WorkflowIcons.flowImage(.progress, size: (size * 1.25).rounded(), square: false) }
        // Things' artwork is drawn on a 28pt canvas with built-in padding; scale so it reads like the symbol size.
        if name == "things.area.plain", let artwork = thingsArtwork(for: "things.area", size: (size * 1.45).rounded()) {
            // Things' sidebar shows the area cube as a grey outline.
            let tinted = NSImage(size: artwork.size, flipped: false) { rect in
                artwork.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            return tinted
        }
        if let artwork = thingsArtwork(for: name, size: (size * 1.45).rounded()) { return artwork }
        let name = name.hasPrefix("things.") ? [
            "things.inbox": "tray", "things.today": "star.fill", "things.upcoming": "calendar",
            "things.anytime": "square.stack.3d.up.fill", "things.someday": "archivebox.fill",
            "things.logbook": "checkmark.circle.fill", "things.area": "shippingbox", "things.evening": "moon.fill",
            "things.project": "circle.lefthalf.filled", "things.deadline": "flag.fill", "things.repeat": "repeat",
            "things.tag": "tag", "things.area.plain": "shippingbox"][name] ?? "circle" : name
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let configured = image.withSymbolConfiguration(config) else { return image }
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}

/// A plain view that paints a dynamic background colour.
class FillView: NSView {
    var fill: NSColor? {
        didSet { needsDisplay = true }
    }

    convenience init(fill: NSColor?) {
        self.init(frame: .zero)
        self.fill = fill
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Views do not clip to bounds on macOS 14+, so never paint the dirty rect itself.
        guard let fill else { return }
        fill.setFill()
        bounds.intersection(dirtyRect).fill(using: .sourceOver)
    }
}

/// A view with a top-left origin, which makes manual list layout straightforward.
class FlippedView: FillView {
    override var isFlipped: Bool { true }
}

/// NSTextView with a placeholder, which AppKit does not provide by itself.
class PlaceholderTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Fonts.regular(12.5),
            .foregroundColor: Theme.placeholder
        ]
        let point = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholderString as NSString).draw(at: point, withAttributes: attributes)
    }
}

class HoverRowView: NSView {
    var isHovered = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if ProcessInfo.processInfo.environment["THINGS4_NO_HOVER"] == "1" { return }
        isHovered = true
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// Things' layout, measured from Things 3 at 760–1800pt window widths:
/// a 240pt sidebar; the left margin grows with the content width (~9.3%),
/// the right margin is 8pt less, and the column caps at ~998pt then centres.
enum Layout {
    static let sidebarWidth: CGFloat = 240
    static let maxColumn: CGFloat = 998
    static let rowHeight: CGFloat = 28

    static func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        var left = (width * 0.093 + 0.5).rounded()
        var column = width - left - (left - 8)
        if column > maxColumn {
            column = maxColumn
            left = ((width - maxColumn) / 2 + 4).rounded()
        }
        return (left, max(280, column))
    }
}

enum Format {
    static func relativeDay(_ date: Date) -> String {
        if date.isToday { return "Today" }
        if date.isTomorrow { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let days = Calendar.current.dateComponents([.day], from: Date().startOfDay, to: date.startOfDay).day ?? 0
        if days > 1 && days < 7 {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: date)
        }
        return date.monthDayString
    }

    static func monthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMMM" : "MMMM yyyy"
        return f.string(from: date)
    }
}
