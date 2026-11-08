import AppKit

/// The menu bar item: Today's count (or the focus countdown) and a popover
/// with Today's to-dos and the timer controls.
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let content = MenuBarListViewController()

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .storeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .focusTimerChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .preferencesChanged, object: nil)
        popover.behavior = .transient
        popover.contentViewController = content
        popover.delegate = self
        update()
    }

    @objc private func update() {
        guard Preferences.menuBarEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            return
        }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.target = self
            item?.button?.action = #selector(toggle)
            item?.button?.imagePosition = .imageLeading
        }
        guard let button = item?.button else { return }
        let timer = FocusTimer.shared
        if timer.isRunning {
            button.image = NSImage(systemSymbolName: timer.isPaused ? "pause.circle" : "timer", accessibilityDescription: "Focus timer")
            button.image?.isTemplate = true
            button.attributedTitle = NSAttributedString(string: " " + timer.remainingText,
                                                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
        } else {
            let count = TaskStore.shared.todayBadgeCount
            button.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Today")
            button.image?.isTemplate = true
            button.attributedTitle = NSAttributedString(string: count > 0 ? " \(count)" : "",
                                                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
        }
        if popover.isShown { content.reload() }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() { popover.performClose(nil) }
}

final class MenuBarListViewController: NSViewController {
    private let stack = NSStackView()
    private let width: CGFloat = 340

    override func loadView() {
        let root = FlippedView(fill: Theme.window)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 10, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            root.widthAnchor.constraint(equalToConstant: width)
        ])
        view = root
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let timer = FocusTimer.shared
        if timer.isRunning { add(FocusPanel(), height: 118) ; add(divider(), height: 9) }

        let header = FlippedView()
        let icon = NSImageView(); icon.image = NSImage.symbol("things.today", size: 14, color: Theme.listColor(.today))
        icon.frame = NSRect(x: 14, y: 6, width: 20, height: 20)
        let title = NSTextField.label("Today", font: Fonts.bold(15), color: Theme.text)
        title.frame = NSRect(x: 40, y: 7, width: 200, height: 20)
        [icon, title].forEach(header.addSubview)
        add(header, height: 32)

        let tasks = TaskStore.shared.tasks(in: .builtin(.today))
        if tasks.isEmpty {
            let empty = NSTextField.label("Nothing left for today.", font: Fonts.regular(13), color: Theme.tertiary)
            let host = FlippedView(); empty.frame = NSRect(x: 16, y: 6, width: 300, height: 18); host.addSubview(empty)
            add(host, height: 30)
        }
        for task in tasks.prefix(14) { add(MiniTaskRow(task: task), height: 30) }
        if tasks.count > 14 {
            let more = NSTextField.label("and \(tasks.count - 14) more…", font: Fonts.regular(12), color: Theme.tertiary)
            let host = FlippedView(); more.frame = NSRect(x: 40, y: 4, width: 200, height: 16); host.addSubview(more)
            add(host, height: 22)
        }
        add(divider(), height: 9)
        let footer = FlippedView()
        let newButton = FlatButton(title: "New To-Do", symbol: "plus", color: Theme.accent, fontSize: 12.5)
        newButton.target = self; newButton.action = #selector(newTodo)
        newButton.frame = NSRect(x: 12, y: 4, width: 110, height: 22)
        let open = FlatButton(title: "Open Things 4", symbol: nil, color: Theme.secondary, fontSize: 12.5)
        open.target = self; open.action = #selector(openApp)
        open.frame = NSRect(x: width - 122, y: 4, width: 110, height: 22)
        [newButton, open].forEach(footer.addSubview)
        add(footer, height: 30)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: width, height: stack.fittingSize.height)
    }

    private func add(_ view: NSView, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    private func divider() -> NSView {
        let host = FlippedView()
        let line = FillView(fill: Theme.separator)
        line.frame = NSRect(x: 12, y: 4, width: width - 24, height: 1)
        host.addSubview(line)
        return host
    }

    @objc private func newTodo() {
        MenuBarController.shared.close()
        QuickEntryWindowController.shared.show()
    }

    @objc private func openApp() {
        MenuBarController.shared.close()
        MainWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A to-do in the menu bar list: checkbox, title, parent, ▶ to start a focus session.
private final class MiniTaskRow: HoverRowView {
    private let task: TaskItem
    private let checkbox = CheckboxView()
    private let title = NSTextField.label("", font: Fonts.regular(13), color: Theme.text)
    private let parent = NSTextField.label("", font: Fonts.regular(11), color: Theme.tertiary)
    private let focus = IconButton(symbol: "play.circle", size: 13, color: Theme.accent, tooltip: "Start a 25-minute focus session")
    override var isFlipped: Bool { true }

    init(task: TaskItem) {
        self.task = task
        super.init(frame: .zero)
        checkbox.isSquare = true
        checkbox.onToggle = { [task] _ in TaskStore.shared.toggleCompletion(task.id) }
        title.stringValue = task.title
        parent.stringValue = task.projectID.flatMap { TaskStore.shared.task($0)?.title } ?? task.areaID.flatMap { TaskStore.shared.area($0)?.title } ?? ""
        focus.target = self
        focus.action = #selector(startFocus)
        focus.isHidden = true
        [checkbox, title, parent, focus].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHovered: Bool { didSet { focus.isHidden = !isHovered } }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 16, y: 8, width: 14, height: 14)
        let parentWidth = parent.stringValue.isEmpty ? 0 : min(110, parent.fittingWidth)
        title.frame = NSRect(x: 40, y: 6, width: bounds.width - 40 - parentWidth - 44, height: 18)
        parent.frame = NSRect(x: bounds.width - parentWidth - 40, y: 8, width: parentWidth, height: 15)
        focus.frame = NSRect(x: bounds.width - 32, y: 4, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.rowHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        MenuBarController.shared.close()
        MainWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openTask, object: task.id)
    }

    @objc private func startFocus() { FocusTimer.shared.start(taskID: task.id) }
}

/// Timer controls shown at the top of the menu bar popover while a session runs.
private final class FocusPanel: FlippedView {
    private let ring = ProgressRing()
    private let time = NSTextField.label("", font: .monospacedDigitSystemFont(ofSize: 26, weight: .semibold), color: Theme.text)
    private let title = NSTextField.label("", font: Fonts.medium(13), color: Theme.secondary)
    private var buttons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let timer = FocusTimer.shared
        ring.color = Theme.accent
        ring.lineWidth = 2.5
        ring.progress = timer.progress
        time.stringValue = timer.remainingText + (timer.isPaused ? "  paused" : "")
        title.stringValue = timer.task?.title ?? ""
        [ring, time, title].forEach(addSubview)
        let specs: [(String, Selector)] = [(timer.isPaused ? "Resume" : "Pause", #selector(pauseResume)), ("+5 min", #selector(plusFive)),
                                           ("Complete", #selector(completeTodo)), ("Stop", #selector(stop))]
        for (label, action) in specs {
            let b = NSButton(title: label, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = Fonts.medium(11.5)
            addSubview(b)
            buttons.append(b)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .focusTimerChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refresh() {
        let timer = FocusTimer.shared
        ring.progress = timer.progress
        time.stringValue = timer.remainingText + (timer.isPaused ? "  paused" : "")
    }

    override func layout() {
        super.layout()
        ring.frame = NSRect(x: 14, y: 10, width: 44, height: 44)
        time.frame = NSRect(x: 68, y: 10, width: 220, height: 32)
        title.frame = NSRect(x: 70, y: 42, width: bounds.width - 84, height: 17)
        var x: CGFloat = 14
        for b in buttons {
            let w = b.intrinsicContentSize.width + 6
            b.frame = NSRect(x: x, y: 74, width: w, height: 26)
            x += w + 6
        }
    }

    @objc private func pauseResume() { FocusTimer.shared.isPaused ? FocusTimer.shared.resume() : FocusTimer.shared.pause() }
    @objc private func plusFive() { FocusTimer.shared.addMinutes(5) }
    @objc private func completeTodo() { FocusTimer.shared.completeTask() }
    @objc private func stop() { FocusTimer.shared.stop() }
}
