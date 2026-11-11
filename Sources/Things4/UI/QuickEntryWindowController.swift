import AppKit
import Carbon

/// Things-style Quick Entry: ⌃Space from any app shows a floating card with the
/// title, notes and field icons; the footer shows where it will be saved.
final class QuickEntryWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    static let shared = QuickEntryWindowController()

    private let checkbox = CheckboxView()
    private let titleField = NSTextField.inlineField(placeholder: "New To-Do", font: Fonts.regular(15))
    private let notesView = MarkdownTextView()
    private let notesScroll = NSScrollView()
    private let whenIcon = IconButton(symbol: "calendar", size: 14, color: Theme.secondary, tooltip: "When")
    private let tagIcon = IconButton(symbol: "tag", size: 14, color: Theme.secondary, tooltip: "Tags")
    private let deadlineIcon = IconButton(symbol: "flag", size: 14, color: Theme.secondary, tooltip: "Deadline")
    private let summaryLabel = NSTextField.label("", font: Fonts.medium(12.5), color: Theme.secondary)
    private let destinationButton = FlatButton(title: "Inbox", symbol: "tray", color: Theme.text, fontSize: 13.5)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var hotKey: HotKey?
    private var autofillHotKey: HotKey?

    // Pending values applied on save.
    private var when: WhenPicker.Choice?
    private var deadline: Date?
    private var tags: [String] = []
    private var projectID: String?
    private var areaID: String?

    private convenience init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 250),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Quick Entry"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.cardElevated
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.init(window: panel)
        buildUI()
        updateHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(updateHotKey), name: .preferencesChanged, object: nil)
    }

    private func buildUI() {
        guard let window else { return }
        let root = FlippedView(fill: Theme.cardElevated)
        window.contentView = root

        checkbox.isSquare = true
        checkbox.onToggle = { _ in }
        titleField.delegate = self

        notesView.configure(baseSize: 14)
        notesView.placeholderString = "Notes"
        notesView.textContainerInset = NSSize(width: 0, height: 2)
        notesView.textContainer?.lineFragmentPadding = 0
        notesView.delegate = self
        notesView.autoresizingMask = [.width]
        notesView.isVerticallyResizable = true
        notesScroll.documentView = notesView
        notesScroll.drawsBackground = false
        notesScroll.borderType = .noBorder
        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true

        let footer = FillView(fill: Theme.card)
        let line = FillView(fill: Theme.separator)

        whenIcon.target = self; whenIcon.action = #selector(whenTapped)
        tagIcon.target = self; tagIcon.action = #selector(tagsTapped)
        deadlineIcon.target = self; deadlineIcon.action = #selector(deadlineTapped)
        destinationButton.target = self; destinationButton.action = #selector(destinationTapped)
        destinationButton.imagePosition = .imageLeading

        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.target = self
        saveButton.action = #selector(save)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        for view in [checkbox, titleField, notesScroll, summaryLabel, whenIcon, tagIcon, deadlineIcon, footer, line,
                     destinationButton, cancelButton, saveButton] {
            root.addSubview(view)
        }
        let width: CGFloat = 560
        checkbox.frame = NSRect(x: 20, y: 22, width: 15, height: 15)
        titleField.frame = NSRect(x: 46, y: 19, width: width - 66, height: 22)
        notesScroll.frame = NSRect(x: 46, y: 48, width: width - 66, height: 92)
        summaryLabel.frame = NSRect(x: 46, y: 152, width: 300, height: 18)
        deadlineIcon.frame = NSRect(x: width - 46, y: 148, width: 26, height: 24)
        tagIcon.frame = NSRect(x: width - 78, y: 148, width: 26, height: 24)
        whenIcon.frame = NSRect(x: width - 110, y: 148, width: 26, height: 24)
        line.frame = NSRect(x: 0, y: 186, width: width, height: 1)
        footer.frame = NSRect(x: 0, y: 187, width: width, height: 63)
        destinationButton.frame = NSRect(x: 18, y: 204, width: 220, height: 26)
        destinationButton.alignment = .left
        saveButton.frame = NSRect(x: width - 100, y: 202, width: 84, height: 30)
        cancelButton.frame = NSRect(x: width - 192, y: 202, width: 84, height: 30)
    }

    @objc private func updateHotKey() {
        if Preferences.quickEntryEnabled {
            if hotKey == nil {
                hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)) {
                    QuickEntryWindowController.shared.toggle()
                }
            }
            if autofillHotKey == nil {
                // ⌃⌥Space: Quick Entry with Autofill, linking what the frontmost app shows.
                autofillHotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) {
                    QuickEntryWindowController.shared.showWithAutofill()
                }
            }
        } else {
            hotKey?.unregister()
            hotKey = nil
            autofillHotKey?.unregister()
            autofillHotKey = nil
        }
    }

    func showWithAutofill() {
        let front = NSWorkspace.shared.frontmostApplication
        let item = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : Links.captureFrontmost(front)
        show(prefill: item?.title ?? "", notes: item?.markdown ?? "")
    }

    func toggle() {
        if window?.isVisible == true { cancel() } else { show() }
    }

    func show(prefill: String = "", notes: String = "") {
        guard let window else { return }
        titleField.stringValue = prefill
        notesView.setMarkdown(notes)
        when = nil; deadline = nil; tags = []; projectID = nil; areaID = nil
        refreshSummary()
        if let screen = NSScreen.main {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                          y: screen.visibleFrame.midY + screen.visibleFrame.height * 0.12))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(titleField)
    }

    private func refreshSummary() {
        var parts: [String] = []
        switch when {
        case .today?: parts.append("★ Today")
        case .evening?: parts.append("☾ This Evening")
        case .date(let d)?: parts.append(Format.relativeDay(d))
        case .someday?: parts.append("Someday")
        case .reminder(let at)?:
            let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
            parts.append("🔔 " + f.string(from: at))
        default: break
        }
        if let deadline { parts.append("⚑ " + Format.relativeDay(deadline)) }
        if !tags.isEmpty { parts.append(tags.joined(separator: ", ")) }
        summaryLabel.stringValue = parts.joined(separator: "   ")
        let store = TaskStore.shared
        if let projectID, let project = store.task(projectID) {
            destinationButton.title = project.title
            destinationButton.image = NSImage.symbol("circle", size: 12, weight: .medium, color: Theme.accent)
        } else if let areaID, let area = store.area(areaID) {
            destinationButton.title = area.title
            destinationButton.image = NSImage.symbol("shippingbox", size: 12, weight: .medium, color: Theme.success)
        } else {
            destinationButton.title = "Inbox"
            destinationButton.image = NSImage.symbol("tray", size: 12, weight: .medium, color: Theme.listColor(.inbox))
        }
    }

    @objc private func whenTapped() {
        WhenPicker.show(mode: .when, current: nil, relativeTo: whenIcon.bounds, of: whenIcon) { [weak self] choice in
            self?.when = choice
            self?.refreshSummary()
        }
    }

    @objc private func deadlineTapped() {
        WhenPicker.show(mode: .deadline, current: deadline, relativeTo: deadlineIcon.bounds, of: deadlineIcon) { [weak self] choice in
            if case .date(let d) = choice { self?.deadline = d } else if case .today = choice { self?.deadline = Date().startOfDay } else { self?.deadline = nil }
            self?.refreshSummary()
        }
    }

    @objc private func tagsTapped() {
        let defaults = ["Errand", "Home", "Office", "Important", "Pending"]
        var names = defaults
        for tag in TaskStore.shared.allTags where !names.contains(tag) { names.append(tag) }
        let rows = names.map { tag in
            SearchListPopover.Row(title: tag, symbol: "tag", color: Theme.secondary, checked: tags.contains(tag)) { [weak self] in
                guard let self else { return }
                if let index = self.tags.firstIndex(of: tag) { self.tags.remove(at: index) } else { self.tags.append(tag) }
                self.refreshSummary()
            }
        }
        SearchListPopover.show(SearchListPopover(placeholder: "Tags", rows: rows), relativeTo: tagIcon.bounds, of: tagIcon)
    }

    @objc private func destinationTapped() {
        let store = TaskStore.shared
        var rows: [SearchListPopover.Row] = [
            .init(title: "Inbox", symbol: "tray.fill", color: Theme.listColor(.inbox), checked: projectID == nil && areaID == nil) { [weak self] in
                self?.projectID = nil; self?.areaID = nil; self?.refreshSummary()
            }
        ]
        for project in store.projects(inArea: nil) where project.isOpen {
            rows.append(.init(title: project.title, symbol: "circle", color: Theme.accent, checked: projectID == project.id) { [weak self] in
                self?.projectID = project.id; self?.areaID = project.areaID; self?.refreshSummary()
            })
        }
        for area in store.areas.sorted(by: { $0.index < $1.index }) {
            rows.append(.init(title: area.title, symbol: "shippingbox", color: Theme.success, checked: areaID == area.id && projectID == nil,
                              bold: true, separatorBefore: true) { [weak self] in
                self?.projectID = nil; self?.areaID = area.id; self?.refreshSummary()
            })
            for project in store.projects(inArea: area.id) where project.isOpen {
                rows.append(.init(title: project.title, symbol: "circle", color: Theme.accent, checked: projectID == project.id) { [weak self] in
                    self?.projectID = project.id; self?.areaID = project.areaID; self?.refreshSummary()
                })
            }
        }
        SearchListPopover.show(SearchListPopover(placeholder: "Move", rows: rows), relativeTo: destinationButton.bounds, of: destinationButton)
    }

    @objc private func save() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { cancel(); return }
        let store = TaskStore.shared
        // "idea: …" files it in Ideas instead of the Inbox.
        if let range = title.range(of: #"^idea\s*:\s*"#, options: [.regularExpression, .caseInsensitive]), !title[range.upperBound...].isEmpty {
            let idea = store.createIdea(title: String(title[range.upperBound...]), notes: notesView.string,
                                        areaID: areaID ?? projectID.flatMap { store.task($0)?.areaID })
            if !tags.isEmpty { store.setTags(idea.id, tags) }
            window?.orderOut(nil)
            return
        }
        var bucket: StartBucket = (projectID != nil || areaID != nil) ? .anytime : .inbox
        var start: Date? = nil
        var evening = false
        switch when {
        case .today?: bucket = .scheduled; start = Date().startOfDay
        case .evening?: bucket = .scheduled; start = Date().startOfDay; evening = true
        case .date(let d)?: bucket = .scheduled; start = d
        case .someday?: bucket = .someday
        case .reminder(let at)?: bucket = .scheduled; start = at.startOfDay
        default: break
        }
        let created = store.createTask(title: title, notes: notesView.string, bucket: bucket, startDate: start, deadline: deadline,
                                       projectID: projectID, areaID: areaID, tags: tags, isEvening: evening)
        if case .reminder(let at)? = when {
            store.setReminder(created.id, at: at)
            ReminderService.shared.requestAuthorization()
        }
        window?.orderOut(nil)
    }

    @objc private func cancel() {
        window?.orderOut(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { save(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        if commandSelector == #selector(NSResponder.insertTab(_:)) { window?.makeFirstResponder(notesView); return true }
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
}
