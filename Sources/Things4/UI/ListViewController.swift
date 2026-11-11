import AppKit

final class ListViewController: NSViewController, NSSearchFieldDelegate, NSMenuItemValidation {
    let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private struct Block {
        let view: NSView
        let height: CGFloat
        let gap: CGFloat
    }

    private let topBar = HeaderBar()
    private let miniTitle = NSTextField.label("Today", font: Fonts.semibold(12.5), color: Theme.text)
    private let searchField = NSSearchField()
    private let searchButton = IconButton(symbol: "magnifyingglass", size: 13, color: Theme.secondary, tooltip: "Quick Find (⌘F)")
    private let addButton = IconButton(symbol: "plus", size: 13, color: Theme.secondary, tooltip: "New To-Do (⌘N)")
    private let aiButton = IconButton(symbol: "sparkles", size: 15, color: Theme.accent, tooltip: "AI sidebar (⇧⌘A)")

    private let scrollView = NSScrollView()
    private let documentView = ListDocumentView()
    private let toolbar = BottomToolbar()

    private var blocks: [Block] = []
    private var rowViews: [String: NSView] = [:]
    /// Selectable items in display order.
    private var orderedIDs: [String] = []
    /// Items whose order can be changed by dragging (to-dos and headings of this list).
    private var reorderableIDs: [String] = []
    private var selectedIDs: Set<String> = []
    private var anchorID: String?
    private var openTaskID: String? {
        didSet {
            // Whatever closed the card, an untouched new to-do goes away (Things behaviour).
            if let old = oldValue, old != openTaskID {
                DispatchQueue.main.async { [weak self] in self?.discardIfUntouched(old) }
            }
        }
    }
    private var editor: TaskEditorView?
    private var reusableEditor: TaskEditorView?
    private var projectHeader: (id: String, view: ListHeaderView)?
    /// Today's cover; kept across rebuilds so hover and reposition state survive.
    private var coverView: CoverView?
    private var pendingFocus: EditorFocus?
    private var searchQuery = ""
    private var addRow: AddTaskRow?
    /// One add row for the lifetime of the controller, so typing several to-dos in a row keeps focus.
    private lazy var persistentAddRow: AddTaskRow = {
        let row = AddTaskRow(placeholder: "New To-Do")
        row.onSubmit = { [weak self] value in
            guard let self else { return }
            _ = self.makeTask(title: value)
            DispatchQueue.main.async { [weak self] in
                guard let self, let addRow = self.addRow else { return }
                self.view.window?.makeFirstResponder(addRow.field)
                self.documentView.scrollToVisible(addRow.frame)
            }
        }
        return row
    }()

    override func loadView() {
        let root = FlippedView(fill: Theme.window)
        view = root

        root.addSubview(topBar)
        root.addSubview(scrollView)
        root.addSubview(toolbar)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        scrollView.scrollerStyle = .overlay

        documentView.onBackgroundClick = { [weak self] in
            guard let self else { return }
            self.closeEditor()
            self.selectedIDs.removeAll()
            self.anchorID = nil
            self.refreshSelection()
        }
        documentView.onDrop = { [weak self] ids, beforeID, headingID in
            self?.handleDrop(ids: ids, beforeID: beforeID, headingID: headingID)
        }
        documentView.onExternalDrop = { [weak self] items, beforeID, headingID in
            self?.createLinkedTodos(items, beforeID: beforeID, headingID: headingID)
        }

        searchField.font = Fonts.regular(12)
        searchField.placeholderString = "Quick Find"
        searchField.isHidden = true
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        topBar.addSubview(searchField)

        // Things keeps the title bar empty; New To-Do and Quick Find live in the bottom toolbar.
        topBar.addSubview(aiButton)

        searchButton.target = self
        searchButton.action = #selector(toggleSearch)
        addButton.target = self
        addButton.action = #selector(addTapped)
        aiButton.target = self
        aiButton.action = #selector(aiTapped)

        toolbar.addButton.target = self
        toolbar.addButton.action = #selector(addTapped)
        toolbar.searchButton.target = self
        toolbar.searchButton.action = #selector(focusSearch)
        toolbar.whenButton.target = self
        toolbar.whenButton.action = #selector(showWhen(_:))
        toolbar.headingButton.target = self
        toolbar.headingButton.action = #selector(newHeadingAction(_:))
        toolbar.moveButton.target = self
        toolbar.moveButton.action = #selector(showMove(_:))
        toolbar.deleteButton.target = self
        toolbar.deleteButton.action = #selector(deleteSelected(_:))
        toolbar.moreButton.target = self
        toolbar.moreButton.action = #selector(showMoreMenu(_:))

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(storeChanged), name: .storeDidChange, object: nil)
        center.addObserver(self, selector: #selector(selectionChanged), name: .selectionDidChange, object: state)
        center.addObserver(self, selector: #selector(focusQuickAdd), name: .focusQuickAdd, object: nil)
        center.addObserver(self, selector: #selector(focusSearch), name: .focusSearch, object: nil)
        center.addObserver(self, selector: #selector(focusQuickAdd), name: .newTask, object: nil)
        center.addObserver(self, selector: #selector(openTaskNotification(_:)), name: .openTask, object: nil)
        center.addObserver(self, selector: #selector(preferencesChanged), name: .preferencesChanged, object: nil)
        center.addObserver(self, selector: #selector(storeChanged), name: .calendarDidChange, object: nil)
        center.addObserver(self, selector: #selector(focusChanged), name: .focusTimerChanged, object: nil)

        preferencesChanged()
        rebuild(preserveScroll: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(documentView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let toolbarHeight: CGFloat = 42
        topBar.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 52)
        scrollView.frame = NSRect(x: 0, y: 52, width: view.bounds.width, height: max(0, view.bounds.height - 52 - toolbarHeight))
        toolbar.frame = NSRect(x: 0, y: view.bounds.height - toolbarHeight, width: view.bounds.width, height: toolbarHeight)

        let width = topBar.bounds.width
        miniTitle.sizeToFit()
        miniTitle.frame = NSRect(x: 24, y: 17, width: min(220, max(60, width - 260)), height: 18)

        var x = width - 42
        if !aiButton.isHidden {
            aiButton.frame = NSRect(x: x, y: 13, width: 28, height: 26)
            x -= 36
        }
        addButton.frame = NSRect(x: x, y: 13, width: 28, height: 26)
        x -= 36
        searchButton.frame = NSRect(x: x, y: 13, width: 28, height: 26)
        searchField.frame = NSRect(x: x - 258, y: 13, width: 244, height: 24)

        layoutBlocks()
    }

    @objc private func preferencesChanged() {
        defer { rebuild(preserveScroll: true) }
        aiButton.isHidden = !Preferences.aiEnabled
        view.needsLayout = true
        if openTaskID != nil { rebuild(preserveScroll: true) }
    }

    // MARK: - Notifications

    @objc private func openTaskNotification(_ notification: Notification) {
        guard let id = notification.object as? String, let task = TaskStore.shared.task(id) else { return }
        let home = TaskStore.shared.homeSelection(for: task)
        searchQuery = ""
        searchField.stringValue = ""
        searchField.isHidden = true
        if state.selection != home {
            state.selection = home
        }
        selectedIDs = [id]
        anchorID = id
        openTaskID = (notification.userInfo?["edit"] as? Bool) == true && task.isTodo ? id : nil
        rebuild(preserveScroll: false)
        scrollToRow(id)
        if task.isIdea && task.isOpen { openPage(for: id) }
    }

    private var logTimer: Timer?
    private var lastFocusID: String?

    @objc private func focusChanged() {
        guard FocusTimer.shared.taskID != lastFocusID else { return }
        lastFocusID = FocusTimer.shared.taskID
        rebuild(preserveScroll: true)
    }

    @objc private func storeChanged() {
        animateNextRebuild = true
        rebuild(preserveScroll: true)
        // Completed items linger briefly, then slide off to the Logbook.
        if Preferences.logImmediately, TaskStore.shared.tasks.contains(where: { $0.isCompleted && ($0.completedAt.map { Date().timeIntervalSince($0) < 3 } ?? false) }) {
            logTimer?.invalidate()
            logTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { [weak self] _ in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    self.rebuild(preserveScroll: true)
                }
            }
        }
    }

    @objc private func selectionChanged() {
        tagFilter = nil
        closeEditor()
        selectedIDs.removeAll()
        anchorID = nil
        searchQuery = ""
        searchField.stringValue = ""
        searchField.isHidden = true
        rebuild(preserveScroll: false)
        view.window?.makeFirstResponder(documentView)
    }

    @objc private func focusQuickAdd() {
        if showsAddRow(for: state.selection) && searchQuery.isEmpty {
            newTaskBelow(nil)
        } else {
            QuickEntryWindowController.shared.show()
        }
    }

    @objc private func focusSearch() {
        guard view.window?.isKeyWindow == true || MainWindowController.active?.root.listVC === self else { return }
        openQuickFind(initial: "")
    }

    /// Things' Quick Find popover, anchored at the top centre of the list.
    func openQuickFind(initial: String) {
        let controller = SearchListPopover.quickFind { [weak self] query in
            guard let self else { return }
            self.searchQuery = query
            self.searchField.stringValue = query
            self.searchField.isHidden = false
            self.rebuild(preserveScroll: false)
        }
        let anchor = NSRect(x: view.bounds.midX - 1, y: view.bounds.height - 60, width: 2, height: 2)
        SearchListPopover.show(controller, relativeTo: anchor, of: view)
        if !initial.isEmpty { controller.setInitialQuery(initial) }
    }

    @objc private func toggleSearch() {
        searchField.isHidden.toggle()
        if !searchField.isHidden {
            view.window?.makeFirstResponder(searchField)
        } else {
            searchQuery = ""
            searchField.stringValue = ""
            rebuild(preserveScroll: true)
        }
    }

    @objc private func addTapped() {
        guard showsAddRow(for: state.selection) else {
            QuickEntryWindowController.shared.show()
            return
        }
        focusQuickAdd()
    }

    @objc private func aiTapped() {
        NotificationCenter.default.post(name: .aiPanelToggle, object: nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        searchQuery = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        rebuild(preserveScroll: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.isHidden = true
            searchQuery = ""
            searchField.stringValue = ""
            rebuild(preserveScroll: false)
            view.window?.makeFirstResponder(documentView)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), let first = orderedIDs.first {
            NotificationCenter.default.post(name: .openTask, object: first)
            return true
        }
        return false
    }

    // MARK: - Rebuild

    func rebuild(preserveScroll: Bool) {
        let origin = scrollView.contentView.bounds.origin
        let animate = animateNextRebuild && Self.animationsEnabled && rowViews.count < 400
        animateNextRebuild = false
        var oldFrames: [String: NSRect] = [:]
        var oldFlows: [String: Flow] = [:]
        if animate {
            for (id, view) in rowViews {
                guard let row = view as? TaskRowView, row.superview === documentView else { continue }
                oldFrames[id] = row.frame
                oldFlows[id] = row.task.flow
            }
        }
        defer { if animate { animateMoves(from: oldFrames, flows: oldFlows) } }
        let previousEditor = editor
        reusableEditor = previousEditor
        defer { reusableEditor = nil }
        let keptHeader = projectHeader?.view
        for block in blocks where block.view !== previousEditor && block.view !== persistentAddRow && block.view !== keptHeader && block.view !== coverView {
            block.view.removeFromSuperview()
        }
        blocks.removeAll()
        rowViews.removeAll()
        orderedIDs.removeAll()
        reorderableIDs.removeAll()
        addRow = nil
        editor = nil

        let selection = state.selection
        miniTitle.stringValue = title(for: selection)

        if !searchQuery.isEmpty {
            buildSearchResults()
        } else {
            viewOptions = ViewOptions.load(for: selection)
            let managed = ViewOptions.key(for: selection) != nil
            wideLayout = managed && viewOptions.layout != .list
            reorderLocked = managed && !(viewOptions.layout == .list && viewOptions.grouping == .sections)
            updateHeader(for: selection)
            appendTagFilterBar(for: selection)
            appendWorkflowChrome(for: selection)
            buildBody(for: selection)
        }

        // Things has no inline "New To-Do" row: + / ⌘N / Space create one and open it.
        persistentAddRow.removeFromSuperview()

        if let coverView, !blocks.contains(where: { $0.view === coverView }) {
            coverView.removeFromSuperview()
            self.coverView = nil
        }

        if let keptHeader, !blocks.contains(where: { $0.view === keptHeader }) {
            keptHeader.removeFromSuperview()
            if projectHeader?.view === keptHeader { projectHeader = nil }
        }

        // An editor that was not re-attached belongs to a task that is no longer listed.
        if let previousEditor, editor !== previousEditor {
            previousEditor.commitAll()
            previousEditor.removeFromSuperview()
        }

        // Drop any selection that no longer exists.
        selectedIDs = selectedIDs.filter { orderedIDs.contains($0) }
        if let openTaskID, !orderedIDs.contains(openTaskID) { self.openTaskID = nil }
        documentView.canReorder = canReorder(selection) && searchQuery.isEmpty && !reorderLocked
        refreshSelection()
        layoutBlocks()

        if preserveScroll {
            let maxY = max(0, documentView.bounds.height - scrollView.contentSize.height)
            let target = NSPoint(x: 0, y: min(origin.y, maxY))
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        if let pendingFocus, let editor {
            self.pendingFocus = nil
            DispatchQueue.main.async { editor.focus(pendingFocus) }
        }
    }

    private func buildBody(for selection: Selection) {
        let store = TaskStore.shared
        switch selection {
        case .builtin(.today):
            appendEvents(on: Date())
            let tasks = store.tasks(in: selection)
            let day = tasks.filter { !$0.isEvening }
            let evening = tasks.filter(\.isEvening)
            let unseen = tasks.filter { !Preferences.seenToday.contains($0.id) }
            if !unseen.isEmpty {
                append(block: NewTodosBanner(count: unseen.count) { [weak self] in
                    Preferences.seenToday = Preferences.seenToday.union(tasks.map(\.id))
                    self?.rebuild(preserveScroll: true)
                }, height: 34, gap: 14)
            }
            if Preferences.groupToday {
                buildGrouped(day, collapse: false)
            } else {
                for task in day { appendTask(task, showProject: true) }
            }
            if !evening.isEmpty {
                append(block: SectionHeaderView(title: "This Evening", symbol: "moon.fill", color: Theme.evening, large: true),
                       height: 40, gap: 6)
                for task in evening { appendTask(task, showProject: true) }
            }
            appendRecentlyCompleted(store.recentlyCompleted(in: selection), showProject: true)
            if tasks.isEmpty { appendEmptyState(for: selection) }

        case .builtin(.upcoming):
            buildUpcoming(store.tasks(in: selection))

        case .builtin(.logbook):
            buildLogbook(store.tasks(in: selection))

        case .builtin(.trash):
            let tasks = store.tasks(in: selection)
            for task in tasks { appendTask(task, showProject: true) }
            if tasks.isEmpty { appendEmptyState(for: selection) }

        case .builtin(.anytime), .builtin(.someday):
            buildGrouped(store.tasks(in: selection))
            if store.tasks(in: selection).isEmpty { appendEmptyState(for: selection) }

        case .builtin(.active):
            let tasks = store.tasks(in: selection)
            buildWorkflow(tasks, selection: selection, showProject: true)
            if tasks.isEmpty { appendEmptyState(for: selection) }

        case .builtin(.ideas):
            buildIdeas(store.ideas)

        case .builtin:
            let tasks = store.tasks(in: selection)
            for task in tasks { appendTask(task, showProject: true) }
            appendRecentlyCompleted(store.recentlyCompleted(in: selection), showProject: true)
            if tasks.isEmpty { appendEmptyState(for: selection) }

        case .project(let id) where reorderLocked:
            appendCompletePrompt(id)
            buildWorkflow(store.children(of: id).filter(\.isTodo), selection: selection, showProject: false)

        case .project(let id):
            appendCompletePrompt(id)
            buildProject(id)

        case .area(let id) where reorderLocked:
            buildWorkflow(store.areaTodos(id), selection: selection, showProject: false)

        case .area(let id):
            let projects = store.projects(inArea: id).filter(\.isOpen)
            let headings = store.headings(inArea: id).filter(\.isOpen)
            let headingIDs = Set(headings.map(\.id))
            let tasks = store.tasks(in: selection)
            let loose = tasks.filter { $0.headingID == nil || !headingIDs.contains($0.headingID!) }
            // Things: an area lists its projects first, then its to-dos.
            for project in projects { appendTask(project, showProject: false) }
            if !projects.isEmpty && (!loose.isEmpty || !headings.isEmpty) { append(block: FlippedView(), height: 15, gap: 0) }
            for task in loose { appendTask(task, showProject: false) }
            for heading in headings {
                appendHeading(heading)
                for task in tasks where task.headingID == heading.id { appendTask(task, showProject: false) }
            }
            appendRecentlyCompleted(store.recentlyCompleted(in: selection), showProject: false)
            if tasks.isEmpty && projects.isEmpty && headings.isEmpty { appendEmptyState(for: selection) }

        case .tag:
            let tasks = store.tasks(in: selection)
            for task in tasks { appendTask(task, showProject: true) }
            if tasks.isEmpty { appendEmptyState(for: selection) }
        }
    }

    private func buildProject(_ id: String) {
        let store = TaskStore.shared
        let children = store.children(of: id)
        let headings = children.filter { $0.isHeading && $0.isOpen }
        let headingIDs = Set(headings.map(\.id))
        // Things keeps to-dos that start later (future date or Someday) at the bottom.
        func isLater(_ t: TaskItem) -> Bool {
            t.bucket == .someday || (t.bucket == .scheduled && (t.startDate ?? .distantPast) >= Date().startOfDay.addingDays(1))
        }
        let laterCount = children.filter { $0.isTodo && $0.isOpen && isLater($0) }.count
        let showLater = !hiddenLater.contains(id)
        let active = children.filter { $0.isTodo && $0.isOpen && (showLater || !isLater($0)) }
        let later: [TaskItem] = []
        let loose = active.filter { $0.headingID == nil || !headingIDs.contains($0.headingID!) }
            .sorted { (isLater($0) ? 1 : 0, $0.index) < (isLater($1) ? 1 : 0, $1.index) }
        for task in loose { appendTask(task, showProject: false) }
        for heading in headings {
            appendHeading(heading)
            for task in active where task.headingID == heading.id {
                appendTask(task, showProject: false)
            }
        }
        _ = later
        if laterCount > 0 {
            let label = showLater ? "Hide later item\(laterCount == 1 ? "" : "s")" : "Show \(laterCount) later item\(laterCount == 1 ? "" : "s")"
            append(block: FlippedView(), height: 24, gap: 0)
            append(block: LinkRowView(title: label) { [weak self] in
                guard let self else { return }
                if self.hiddenLater.contains(id) { self.hiddenLater.remove(id) } else { self.hiddenLater.insert(id) }
                self.rebuild(preserveScroll: true)
            }, height: 28, gap: 0)
        }
        appendRecentlyCompleted(store.recentlyCompleted(in: .project(id)), showProject: false)
        if loose.isEmpty && headings.isEmpty { appendEmptyState(for: .project(id)) }
    }

    private var expandedGroups: Set<String> = []
    private var hiddenLater: Set<String> = []

    // MARK: - Workflow views

    private var viewOptions = ViewOptions(layout: .list, grouping: .sections, filter: .all)
    /// Board and Table span the window; the list keeps the reading column.
    private var wideLayout = false
    /// Grouped, board and table views order to-dos themselves, so dragging does not reorder.
    private var reorderLocked = false
    /// Status groups the user has flipped from their default (Done and Canceled start collapsed).
    private var toggledGroups: Set<String> = []
    private var animateNextRebuild = false
    private static let animationsEnabled = !CommandLine.arguments.contains { $0.hasPrefix("--") }

    private func setViewOptions(_ change: (inout ViewOptions) -> Void) {
        var options = viewOptions
        change(&options)
        options.save(for: state.selection)
        closeEditor()
        rebuild(preserveScroll: true)
    }

    /// Chips, progress bar and the List / Board / Table bar under a project, area or Active title.
    private func appendWorkflowChrome(for selection: Selection) {
        guard ViewOptions.key(for: selection) != nil else { return }
        let store = TaskStore.shared
        func chip(_ flow: Flow, _ count: Int, _ text: String) -> WorkflowStatsView.Chip {
            .init(image: WorkflowIcons.flowImage(flow, size: 12), strong: "\(count)", text: text)
        }
        func focusChip(_ items: [TaskItem]) -> WorkflowStatsView.Chip? {
            let tracked = store.trackedTotal(items), estimate = store.estimateTotal(items.filter(\.isOpen)) * 60
            guard tracked >= 60 || estimate > 0 else { return nil }
            return .init(image: NSImage.symbol("clock", size: 10, weight: .medium, color: Theme.secondary),
                         strong: Duration.text(seconds: tracked),
                         text: estimate > 0 ? "focused · \(Duration.text(seconds: estimate)) left to do" : "focused")
        }
        switch selection {
        case .project(let id):
            guard let project = store.task(id) else { return }
            let todos = store.children(of: id).filter(\.isTodo)
            let open = todos.filter(\.isOpen)
            let counted = todos.filter { !$0.isCanceled }
            var chips: [WorkflowStatsView.Chip] = []
            if project.isOpen {
                let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                    Theme.flowColor(project.stage == .backlog ? .backlog : (project.stage == .waiting ? .progress : .done)).setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
                    return true
                }
                chips.append(.init(image: dot, strong: project.stage.projectTitle, text: "") { anchor in
                    WorkflowMenus.projectStatus(for: id).popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
                })
            }
            if let deadline = project.deadline {
                chips.append(.init(image: NSImage.symbol("flag", size: 10, weight: .medium, color: Theme.secondary), strong: deadline.monthDayString, text: "target"))
            }
            chips.append(chip(.progress, open.filter { $0.stage == .progress }.count, "in progress"))
            let waiting = open.filter { $0.stage == .waiting }.count
            if waiting > 0 { chips.append(chip(.waiting, waiting, "waiting")) }
            if let focus = focusChip(todos) { chips.append(focus) }
            let total = Double(max(1, counted.count))
            let done = counted.filter(\.isCompleted).count
            let stats = WorkflowStatsView(chips: chips,
                                          bar: counted.isEmpty ? nil : (Double(done) / total, Double(open.filter { $0.stage == .progress }.count) / total, Double(waiting) / total),
                                          barLabel: "\(done) of \(counted.count) done")
            append(block: stats, height: WorkflowStatsView.height(hasBar: !counted.isEmpty), gap: 16)
        case .area(let id):
            let todos = store.areaTodos(id)
            let open = todos.filter(\.isOpen)
            var chips = [chip(.progress, open.filter { $0.stage == .progress }.count, "in progress"),
                         chip(.waiting, open.filter { $0.stage == .waiting }.count, "waiting"),
                         chip(.todo, open.filter { $0.stage == .todo }.count, "up next")]
            if let focus = focusChip(todos) { chips.append(focus) }
            append(block: WorkflowStatsView(chips: chips), height: WorkflowStatsView.height(hasBar: false), gap: 16)
        default:
            break
        }

        let bar = ViewOptionsBar(options: viewOptions, showsLayouts: selection != .builtin(.active))
        bar.onLayout = { [weak self] layout in self?.setViewOptions { $0.layout = layout } }
        bar.onFilter = { [weak self] anchor in
            guard let self else { return }
            let menu = NSMenu()
            for filter in ListFilter.allCases {
                menu.addItem(ClosureMenuItem(filter.title, checked: self.viewOptions.filter == filter) { self.setViewOptions { $0.filter = filter } })
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
        bar.onGroup = { [weak self] anchor in
            guard let self else { return }
            let menu = NSMenu()
            for grouping in ViewOptions.groupings(for: selection) {
                menu.addItem(ClosureMenuItem(grouping.title, checked: self.viewOptions.grouping == grouping) { self.setViewOptions { $0.grouping = grouping } })
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
        append(block: bar, height: 28, gap: 10)
    }

    /// When the last to-do of a project is done, offer to finish the project too.
    private func appendCompletePrompt(_ id: String) {
        let store = TaskStore.shared
        guard let project = store.task(id), project.isOpen else { return }
        let todos = store.children(of: id).filter { $0.isTodo && !$0.isCanceled }
        guard !todos.isEmpty, todos.allSatisfy(\.isCompleted) else { return }
        append(block: LinkRowView(title: "Every to-do is done. Complete Project") { [weak self] in self?.completeProject(id) }, height: 28, gap: 6)
    }

    private var taskActions: TaskActions {
        TaskActions(
            select: { [weak self] task, event in self?.handleSelect(task, event: event) },
            open: { task, view in TaskEditorPopover.show(taskID: task.id, from: view) },
            toggle: { task, alternate in
                if alternate && task.isOpen { TaskStore.shared.cancel(task.id) } else { TaskStore.shared.toggleCompletion(task.id) }
            },
            contextMenu: { [weak self] task, event in self?.showContextMenu(for: task, event: event) },
            dragIDs: { [weak self] id in
                guard let self, self.selectedIDs.contains(id) else { return [id] }
                return self.orderedIDs.filter { self.selectedIDs.contains($0) }
            })
    }

    /// A project, area or Active as a grouped list, a board or a table.
    private func buildWorkflow(_ todos: [TaskItem], selection: Selection, showProject: Bool) {
        let store = TaskStore.shared
        let options = viewOptions
        var items = todos.filter { options.filter.matches($0) }
        if let tagFilter { items = items.filter { $0.tags.contains(tagFilter) } }
        let open = items.filter(\.isOpen)
        let closed = items.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        func byFlow(_ list: [TaskItem]) -> [TaskItem] {
            list.sorted { (Flow.listOrder.firstIndex(of: $0.flow) ?? 0, $0.index) < (Flow.listOrder.firstIndex(of: $1.flow) ?? 0, $1.index) }
        }
        let key = ViewOptions.key(for: selection) ?? ""

        switch options.layout {
        case .board:
            let shown = open + closed.prefix(30)
            var lanes: [BoardView.Lane] = []
            if case .area(let id) = selection {
                for project in store.projects(inArea: id) where project.isOpen {
                    let tasks = shown.filter { $0.projectID == project.id }
                    if !tasks.isEmpty { lanes.append(.init(projectID: project.id, title: project.title, tasks: tasks)) }
                }
                let loose = shown.filter { $0.projectID == nil }
                if !loose.isEmpty { lanes.append(.init(projectID: nil, title: "No Project", tasks: loose)) }
            }
            if lanes.isEmpty { lanes = [.init(projectID: nil, title: nil, tasks: shown)] }
            let board = BoardView(lanes: lanes)
            board.actions = taskActions
            board.onMove = { ids, flow in store.batch("Set Status") { ids.forEach { store.setFlow($0, flow) } } }
            board.onAdd = { [weak self] flow in self?.newTask(in: flow) }
            board.onLane = { [weak self] id in self?.state.selection = .project(id) }
            for id in board.orderedIDs {
                orderedIDs.append(id)
                rowViews[id] = board.cards[id]
            }
            append(block: board, height: 300, gap: 0)

        case .table:
            let table = TaskTableView(tasks: byFlow(open) + closed.prefix(50), showProject: showProject || selection != .builtin(.active) && { if case .area = selection { return true }; return false }())
            table.actions = taskActions
            table.onCell = { cell, task, view, rect in
                let menu: NSMenu
                switch cell {
                case .status: menu = WorkflowMenus.status(for: [task.id])
                case .priority: menu = WorkflowMenus.priority(for: [task.id])
                case .estimate: menu = WorkflowMenus.estimate(for: [task.id])
                }
                menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: view)
            }
            for id in table.orderedIDs {
                orderedIDs.append(id)
                rowViews[id] = table.rows[id]
            }
            append(block: table, height: 200, gap: 0)

        case .list:
            func group(_ id: String, title: String, image: NSImage?, tasks: [TaskItem], startsCollapsed: Bool = false, add: Flow? = nil) {
                let groupKey = key + ":" + id
                var collapsed = startsCollapsed != toggledGroups.contains(groupKey)
                if let openTaskID, tasks.contains(where: { $0.id == openTaskID }) { collapsed = false }
                let header = StatusGroupHeader(title: title, count: tasks.count, image: image, collapsed: collapsed,
                                               canAdd: add != nil && showsAddRow(for: selection))
                header.onToggle = { [weak self] in
                    guard let self else { return }
                    if self.toggledGroups.contains(groupKey) { self.toggledGroups.remove(groupKey) } else { self.toggledGroups.insert(groupKey) }
                    self.rebuild(preserveScroll: true)
                }
                header.onAdd = { [weak self] in if let add { self?.newTask(in: add) } }
                append(block: header, height: 36, gap: 5)
                if !collapsed { for task in tasks { appendTask(task, showProject: showProject) } }
                append(block: FlippedView(), height: 16, gap: 0)
            }
            switch options.grouping {
            case .priority:
                for priority in Priority.allCases.reversed() {
                    let tasks = byFlow(open.filter { $0.priority == priority })
                    if !tasks.isEmpty { group("p\(priority.rawValue)", title: priority.title, image: WorkflowIcons.priorityImage(priority), tasks: tasks) }
                }
            case .project:
                let loose = byFlow(open.filter { $0.projectID == nil })
                var rank: [String: Int] = [:]
                for (index, project) in (store.projects(inArea: nil) + store.areas.sorted { $0.index < $1.index }.flatMap { store.projects(inArea: $0.id) }).enumerated() {
                    rank[project.id] = index
                }
                let projectIDs = Array(Set(open.compactMap(\.projectID))).sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
                for projectID in projectIDs {
                    let header = GroupHeaderView(title: store.task(projectID)?.title ?? "Project", projectID: projectID, color: Theme.accent)
                    header.onClick = { [weak self] in self?.state.selection = .project(projectID) }
                    append(block: header, height: 44, gap: 6)
                    for task in byFlow(open.filter { $0.projectID == projectID }) { appendTask(task, showProject: false) }
                    append(block: FlippedView(), height: 18, gap: 0)
                }
                if !loose.isEmpty { group("loose", title: "No Project", image: nil, tasks: loose) }
            case .none:
                for task in byFlow(open) { appendTask(task, showProject: showProject) }
            default:
                let active = selection == .builtin(.active)
                // Like Things, a to-do finished today stays where it was, greyed out; it joins Done tomorrow.
                let recentIDs = Set((active ? store.recentlyCompleted(in: selection) : closed.filter { ($0.completedAt ?? .distantPast) >= (Preferences.logImmediately ? Date().addingTimeInterval(-2.5) : Date().startOfDay) }).map(\.id))
                let recent = (active ? store.recentlyCompleted(in: selection) : closed).filter { recentIDs.contains($0.id) }
                for flow in active ? [Flow.progress, .waiting] : Flow.listOrder {
                    let tasks = flow.stage == nil ? Array(closed.filter { $0.flow == flow && !recentIDs.contains($0.id) }.prefix(60))
                        : open.filter { $0.flow == flow } + recent.filter { $0.stage == flow.stage }
                    let isProject: Bool = { if case .project = selection { return true }; return false }()
                    guard !tasks.isEmpty || (isProject && flow == .todo) else { continue }
                    group(flow.rawValue, title: flow.title, image: WorkflowIcons.flowImage(flow), tasks: tasks,
                          startsCollapsed: flow.stage == nil, add: flow.stage == nil ? nil : flow)
                }
            }
        }
    }

    /// Ideas grouped by how far they've been thought through, nearest to ready first.
    private func buildIdeas(_ ideas: [TaskItem]) {
        guard !ideas.isEmpty else {
            appendEmptyState(for: .builtin(.ideas))
            return
        }
        for stage in IdeaStage.allCases.reversed() {
            let group = ideas.filter { $0.ideaStage == stage }
            guard !group.isEmpty else { continue }
            let groupKey = "ideas:" + stage.rawValue
            let collapsed = toggledGroups.contains(groupKey)
            let header = StatusGroupHeader(title: stage.title, count: group.count, image: IdeaIcons.stageImage(stage),
                                           collapsed: collapsed, canAdd: true)
            header.onToggle = { [weak self] in
                guard let self else { return }
                if self.toggledGroups.contains(groupKey) { self.toggledGroups.remove(groupKey) } else { self.toggledGroups.insert(groupKey) }
                self.rebuild(preserveScroll: true)
            }
            header.onAdd = { [weak self] in self?.newIdea(stage: stage) }
            append(block: header, height: 36, gap: 5)
            if !collapsed {
                for idea in group { appendIdea(idea) }
            }
            append(block: FlippedView(), height: 16, gap: 0)
        }
    }

    private func appendIdea(_ idea: TaskItem) {
        let row = IdeaRowView(idea: idea)
        row.isSelectedRow = selectedIDs.contains(idea.id)
        row.onSelect = { [weak self] idea, event in self?.handleSelect(idea, event: event) }
        row.onOpen = { [weak self] idea in self?.openPage(for: idea.id) }
        row.onContextMenu = { [weak self, weak row] idea, event in
            guard let self, let row else { return }
            if !self.selectedIDs.contains(idea.id) { self.selectOnly(idea.id) }
            let menu = IdeaActions.contextMenu(for: idea.id) { [weak self] in self?.openPage(for: idea.id) }
            NSMenu.popUpContextMenu(menu, with: event, for: row)
        }
        rowViews[idea.id] = row
        orderedIDs.append(idea.id)
        append(block: row, height: IdeaRowView.height, gap: 0)
    }

    /// Creates an idea and opens it as a page, title selected.
    func newIdea(stage: IdeaStage = .raw) {
        let idea = TaskStore.shared.createIdea(title: "", stage: stage)
        openPage(for: idea.id)
    }

    /// A new to-do in this view that starts in the given status.
    private func newTask(in flow: Flow) {
        guard showsAddRow(for: state.selection) else { return }
        if let open = openTaskID { editor?.commitAll(); discardIfUntouched(open) }
        let task = makeTask(title: "New To-Do")
        if let stage = flow.stage, stage != .todo { TaskStore.shared.setStage(task.id, stage) }
        present(newTaskID: task.id)
    }

    /// Opens a just-created to-do: inline in a list, in a popover on a board or table.
    private func present(newTaskID id: String) {
        selectedIDs = [id]
        anchorID = id
        if wideLayout {
            openTaskID = nil
            rebuild(preserveScroll: true)
            if let view = rowViews[id] { TaskEditorPopover.show(taskID: id, from: view) }
            return
        }
        openTaskID = id
        pendingFocus = .title
        rebuild(preserveScroll: true)
        scrollToRow(id)
    }

    private func animateMoves(from oldFrames: [String: NSRect], flows: [String: Flow]) {
        guard !oldFrames.isEmpty else { return }
        for (id, view) in rowViews {
            guard let row = view as? TaskRowView, row.superview === documentView, let old = oldFrames[id] else { continue }
            if let flow = flows[id], flow != row.task.flow { row.checkbox.pop() }
            let target = row.frame
            guard abs(old.minY - target.minY) > 1 else { continue }
            row.frame = NSRect(x: target.minX, y: old.minY, width: target.width, height: target.height)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                row.animator().frame = target
            }
        }
    }
    /// Things' tag filter bar: nil = All.
    private var tagFilter: String?

    /// Anytime / Someday: loose to-dos first, then one group per area and project.
    private func buildGrouped(_ tasks: [TaskItem], collapse: Bool = true) {
        let store = TaskStore.shared
        let loose = tasks.filter { $0.projectID == nil && $0.areaID == nil }
        for task in loose { appendTask(task, showProject: false) }
        if !loose.isEmpty { append(block: FlippedView(), height: 18, gap: 0) }
        var order: [String] = []
        var groups: [String: [TaskItem]] = [:]
        for task in tasks where task.projectID != nil || task.areaID != nil {
            let key = task.projectID.map { "p:" + $0 } ?? "a:" + task.areaID!
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(task)
        }
        // Things orders groups like the sidebar: loose projects, then each area followed by its projects.
        var rank: [String: Int] = [:]
        var r = 0
        for project in store.projects(inArea: nil) { rank["p:" + project.id] = r; r += 1 }
        for area in store.areas.sorted(by: { $0.index < $1.index }) {
            rank["a:" + area.id] = r; r += 1
            for project in store.projects(inArea: area.id) { rank["p:" + project.id] = r; r += 1 }
        }
        order.sort { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
        for key in order {
            let items = groups[key]!
            let isProject = key.hasPrefix("p:")
            let id = String(key.dropFirst(2))
            let title = isProject ? (store.task(id)?.title ?? "Project") : (store.area(id)?.title ?? "Area")
            let header = GroupHeaderView(title: title, projectID: isProject ? id : nil, color: Theme.accent)
            header.onClick = { self.state.selection = isProject ? .project(id) : .area(id) }
            append(block: header, height: 44, gap: 6)
            let limit = (!collapse || expandedGroups.contains(key)) ? items.count : min(items.count, 3)
            for task in items.prefix(limit) { appendTask(task, showProject: false) }
            if items.count > limit {
                append(block: ShowMoreView(count: items.count - limit) { [weak self] in
                    self?.expandedGroups.insert(key)
                    self?.rebuild(preserveScroll: true)
                }, height: 28, gap: 0)
            }
            append(block: FlippedView(), height: 21, gap: 0)
        }
    }

    private func appendCalendarPrompt() {
        // Also shown when calendars are on but macOS no longer grants access.
        let lostAccess = Preferences.calendarsEnabled && !CalendarService.shared.hasAccess
        guard lostAccess || (!Preferences.calendarsEnabled && !Preferences.calendarPromptDismissed) else { return }
        let card = CalendarPromptCard(onNo: {
            Preferences.calendarPromptDismissed = true
        }, onYes: { [weak self] in
            CalendarService.shared.requestAccess { granted in
                Preferences.calendarsEnabled = granted
                if !granted {
                    let alert = NSAlert()
                    alert.messageText = "Calendar access is off"
                    alert.informativeText = "Allow Things 4 in System Settings › Privacy & Security › Calendars, then try again."
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
                self?.rebuild(preserveScroll: true)
            }
        })
        append(block: card, height: 88, gap: 22)
    }

    private func buildUpcoming(_ tasks: [TaskItem]) {
        appendCalendarPrompt()
        let grouped = Dictionary(grouping: tasks) { ($0.startDate ?? $0.deadline ?? Date()).startOfDay }
        let week = (1...7).map { Date().startOfDay.addingDays($0) }
        let later = grouped.keys.filter { $0.daysFromToday > 7 }.sorted()
        var lastMonth: String?
        for date in week {
            append(block: UpcomingDayHeader(date: date), height: 42, gap: 4)
            appendEvents(on: date, followedByTasks: !(grouped[date] ?? []).isEmpty)
            for task in grouped[date] ?? [] { appendTask(task, showProject: true, leading: nil, showsDateChip: false) }
            append(block: FlippedView(), height: 30, gap: 0)
        }
        for date in later {
            let items = grouped[date]!
            do {
                let month = Format.monthYear(date)
                if month != lastMonth {
                    append(block: SectionHeaderView(title: month, large: true), height: 38, gap: 6)
                    lastMonth = month
                }
                for task in items { appendTask(task, showProject: true, leading: date.dayNumberString + " " + String(date.weekdayString.prefix(3))) }
            }
        }
        if tasks.isEmpty { appendEmptyState(for: .builtin(.upcoming)) }
    }

    private func buildLogbook(_ tasks: [TaskItem]) {
        let grouped = Dictionary(grouping: tasks) { ($0.completedAt ?? $0.modifiedAt).startOfDay }
        let dates = grouped.keys.sorted(by: >)
        var lastMonth: String?
        for date in dates {
            let items = grouped[date]!
            if -date.daysFromToday <= 7 {
                append(block: SectionHeaderView(title: Format.relativeDay(date), large: true), height: 38, gap: 6)
                for task in items { appendTask(task, showProject: true, leading: date.isToday ? "today" : Self.logDate(date)) }
            } else {
                let month = Format.monthYear(date)
                if month != lastMonth {
                    append(block: SectionHeaderView(title: month, large: true), height: 38, gap: 6)
                    lastMonth = month
                }
                for task in items { appendTask(task, showProject: true, leading: Self.logDate(date)) }
            }
        }
        if tasks.isEmpty { appendEmptyState(for: .builtin(.logbook)) }
    }

    static func logDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    private func buildSearchResults() {
        let results = TaskStore.shared.search(searchQuery)
        let header = ListHeaderView(title: "Quick Find", subtitle: "\(results.count) result\(results.count == 1 ? "" : "s") for “\(searchQuery)”",
                                    notes: "", progress: nil, color: Theme.accent, symbol: "magnifyingglass")
        append(block: header, height: 80, gap: 12)
        let projects = results.filter(\.isProject)
        let todos = results.filter(\.isTodo)
        let ideas = results.filter { $0.isIdea && $0.isOpen }
        if !ideas.isEmpty {
            append(block: SectionHeaderView(title: "Ideas"), height: 28, gap: 2)
            for idea in ideas { appendIdea(idea) }
        }
        if !projects.isEmpty {
            append(block: SectionHeaderView(title: "Projects"), height: 28, gap: 2)
            for project in projects { appendTask(project, showProject: true, navigateOnSelect: true) }
        }
        if !todos.isEmpty {
            append(block: SectionHeaderView(title: "To-Dos"), height: 32, gap: 2)
            for task in todos { appendTask(task, showProject: true, navigateOnSelect: true) }
        }
        if results.isEmpty {
            append(block: EmptyStateView(title: "No matches.", subtitle: "Titles, notes, tags and checklist items are searched."), height: 64, gap: 0)
        }
    }

    private func appendRecentlyCompleted(_ tasks: [TaskItem], showProject: Bool) {
        guard !tasks.isEmpty else { return }
        if let last = blocks.last, last.view is TaskRowView {
            blocks[blocks.count - 1] = Block(view: last.view, height: last.height, gap: 10)
        }
        for task in tasks { appendTask(task, showProject: showProject) }
    }

    private func appendEmptyState(for selection: Selection) {
        if case .builtin(let list) = selection, list != .upcoming {
            let free = max(200, scrollView.contentSize.height - 160)
            append(block: BigEmptyIconView(symbol: list.symbol), height: free, gap: 0)
            return
        }
        append(block: EmptyStateView(title: emptyTitle(for: selection), subtitle: emptySubtitle(for: selection)),
               height: 64, gap: 0)
    }

    /// - Parameter followedByTasks: tighter spacing when nothing follows (Upcoming days).
    private func appendEvents(on day: Date, followedByTasks: Bool = true) {
        let events = CalendarService.shared.events(on: day)
        guard !events.isEmpty else { return }
        let style: CalendarEventsView.Style = day.isToday ? .card : .list
        let view = CalendarEventsView(events: events, style: style)
        view.extendsLeft = 6
        if style == .card, let last = blocks.last, last.view is ListHeaderView {
            // Things: the event card sits 44pt (centre to centre) under the title.
            blocks[blocks.count - 1] = Block(view: last.view, height: last.height, gap: -6)
        }
        let height = CalendarEventsView.height(for: events, style: style) + (style == .list ? 6 : 0)
        let gap: CGFloat = style == .card ? 26 : (followedByTasks ? 12 : 0)
        append(block: view, height: height, gap: gap)
    }

    private var canAddHeading: Bool {
        switch state.selection {
        case .project(let id): return TaskStore.shared.task(id)?.isOpen ?? false
        case .area: return true
        default: return false
        }
    }

    private func headingMenu(_ heading: TaskItem) -> NSMenu {
        let store = TaskStore.shared
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Archive", symbol: "archivebox") { store.archiveHeading(heading.id) })
        menu.addItem(.separator())
        let moveItem = NSMenuItem(title: "Move…", action: nil, keyEquivalent: "")
        moveItem.image = NSImage.symbol("arrow.right", size: 12, weight: .regular, color: Theme.secondary)
        let moveMenu = NSMenu()
        for project in store.openProjects where project.id != heading.projectID {
            moveMenu.addItem(ClosureMenuItem(project.title) {
                store.batch("Move Heading") {
                    for child in store.tasks where child.headingID == heading.id {
                        store.move(child.id, toProject: project.id, areaID: project.areaID)
                        store.setHeading(child.id, headingID: heading.id)
                    }
                    if var h = store.task(heading.id) { h.projectID = project.id; h.areaID = project.areaID; store.update(h) }
                }
            })
        }
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)
        menu.addItem(ClosureMenuItem("Convert to Project…", symbol: "circle.dashed") {
            guard Prompt.confirm(title: "Convert “\(heading.title)” into a project?", message: "Its to-dos move into the new project.", button: "Convert") else { return }
            if let project = store.convertToProject(heading.id) { self.state.selection = .project(project.id) }
        })
        menu.addItem(ClosureMenuItem("Rename…", symbol: "pencil") {
            if let title = Prompt.text(title: "Rename Heading", message: "", placeholder: "Heading", initial: heading.title, button: "Rename") {
                store.setTitle(heading.id, title)
            }
        })
        menu.addItem(ClosureMenuItem("Delete", symbol: "trash") { store.moveToTrash(heading.id) })
        return menu
    }

    private func appendHeading(_ heading: TaskItem) {
        let openCount = TaskStore.shared.tasks.filter { $0.headingID == heading.id && $0.isOpen && $0.isTodo }.count
        let row = HeadingRowView(heading: heading, openCount: openCount)
        row.isSelectedRow = selectedIDs.contains(heading.id)
        row.onSelect = { [weak self] item, event in self?.handleSelect(item, event: event) }
        row.onContextMenu = { [weak self] item, event in
            guard let self else { return }
            self.selectedIDs = [item.id]
            self.anchorID = item.id
            self.refreshSelection()
            if let view = self.rowViews[item.id] { NSMenu.popUpContextMenu(self.headingMenu(item), with: event, for: view) }
        }
        row.onDoubleClick = { item in
            if let title = Prompt.text(title: "Rename Section", message: "", placeholder: "Section", initial: item.title, button: "Rename") {
                TaskStore.shared.setTitle(item.id, title)
            }
        }
        rowViews[heading.id] = row
        orderedIDs.append(heading.id)
        reorderableIDs.append(heading.id)
        append(block: row, height: 46, gap: 4)
    }

    private func appendTagFilterBar(for selection: Selection) {
        if case .tag = selection { return }
        if case .builtin(let list) = selection, list == .logbook || list == .trash { return }
        let store = TaskStore.shared
        var items = store.tasks(in: selection)
        if case .project(let id) = selection { items = store.children(of: id).filter { $0.isTodo && $0.isOpen } }
        let tags = Array(Set(items.flatMap(\.tags))).sorted()
        if let tagFilter, !tags.contains(tagFilter) { self.tagFilter = nil }
        guard !tags.isEmpty else { return }
        let bar = TagFilterBar(tags: tags, selected: tagFilter) { [weak self] tag in
            self?.tagFilter = tag
            self?.rebuild(preserveScroll: true)
        }
        // Things leaves a wide band around the tag bar.
        if let last = blocks.last, last.view is ListHeaderView {
            // Under a project's notes Things leaves a wide band; under a plain title the bar sits tight.
            let isProject: Bool = { if case .project = selection { return true }; return false }()
            blocks[blocks.count - 1] = Block(view: last.view, height: last.height, gap: isProject ? 45 : -9)
        }
        append(block: bar, height: 30, gap: 27)
    }

    private func appendTask(_ task: TaskItem, showProject: Bool, leading: String? = nil, navigateOnSelect: Bool = false,
                            showsDateChip: Bool = true) {
        if let tagFilter, task.isTodo, !task.tags.contains(tagFilter), searchQuery.isEmpty { return }
        let isNew = state.selection == .builtin(.today) && task.isOpen && !Preferences.seenToday.contains(task.id)
        let row = TaskRowView(task: task, showProjectName: showProject, leadingText: leading, showsDateChip: showsDateChip, isNew: isNew,
                              hidesTodayStar: state.selection == .builtin(.today) || state.selection == .builtin(.upcoming))
        row.isSelectedRow = selectedIDs.contains(task.id)
        row.isOpenRow = task.id == openTaskID
        row.onSelect = { [weak self] task, event in
            guard let self else { return }
            if navigateOnSelect {
                NotificationCenter.default.post(name: .openTask, object: task.id)
                return
            }
            self.handleSelect(task, event: event)
        }
        row.onOpen = { [weak self] task in
            guard let self else { return }
            if task.isProject {
                state.selection = .project(task.id)
                return
            }
            if navigateOnSelect {
                NotificationCenter.default.post(name: .openTask, object: task.id)
                return
            }
            self.openEditor(for: task.id)
        }
        row.onToggle = { [weak self] task, alternate in
            if alternate && task.isOpen {
                TaskStore.shared.cancel(task.id)
            } else {
                TaskStore.shared.toggleCompletion(task.id)
            }
            if task.id == self?.openTaskID { self?.openTaskID = nil }
        }
        row.onOpenTag = { tag in
            self.state.selection = .tag(tag)
        }
        row.onContextMenu = { [weak self] task, event in self?.showContextMenu(for: task, event: event) }
        row.dragIDs = { [weak self] in
            guard let self else { return [task.id] }
            return self.selectedIDs.contains(task.id) ? self.orderedIDs.filter { self.selectedIDs.contains($0) } : [task.id]
        }
        rowViews[task.id] = row
        orderedIDs.append(task.id)
        if task.isTodo && task.isOpen { reorderableIDs.append(task.id) }
        // Things: the opened card takes the row's place.
        if task.id != openTaskID {
            append(block: row, height: TaskRowView.height(for: task, showsParent: showProject), gap: 0)
        } else {
            append(block: FlippedView(), height: 6, gap: 0)
        }

        if task.id == openTaskID {
            let editor: TaskEditorView
            if let existing = self.editor ?? reusableEditor, existing.task.id == task.id {
                editor = existing
                editor.update(task: task)
            } else {
                editor = TaskEditorView(task: task)
                editor.onClose = { [weak self] in
                    if let id = self?.openTaskID { self?.discardIfUntouched(id) }
                    self?.openTaskID = nil
                    self?.rebuild(preserveScroll: true)
                    self?.view.window?.makeFirstResponder(self?.documentView)
                }
                editor.onReload = { [weak self] in
                    self?.rebuild(preserveScroll: true)
                }
                editor.onHeightChange = { [weak self] in
                    self?.layoutBlocks()
                }
                editor.onAIEnhance = { task in
                    guard Preferences.aiEnabled else { return }
                    self.state.aiDestination = .chat
                    if !self.state.isAIPanelVisible {
                        NotificationCenter.default.post(name: .aiPanelToggle, object: nil)
                    }
                    NotificationCenter.default.post(name: .aiEnhanceTask, object: task.id)
                }
            }
            self.editor = editor
            append(block: editor, height: TaskEditorView.height(for: task, width: contentWidth), gap: 6)
        }
    }

    private func append(block: NSView, height: CGFloat, gap: CGFloat) {
        if block.superview !== documentView { documentView.addSubview(block) }
        blocks.append(Block(view: block, height: height, gap: gap))
    }

    private func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        wideLayout && searchQuery.isEmpty ? (36, max(280, width - 72)) : Layout.column(in: width)
    }

    private var contentWidth: CGFloat {
        column(in: scrollView.contentSize.width).width
    }

    private func layoutBlocks() {
        let scrollWidth = scrollView.contentSize.width
        guard scrollWidth > 10 else { return }
        let (x, contentWidth) = column(in: scrollWidth)
        var y: CGFloat = 9
        var slots: [ListDocumentView.Slot] = []

        for block in blocks {
            if let cover = block.view as? CoverView {
                // Full-bleed, about 30% of the window like Notion.
                let height = min(280, max(150, (scrollView.contentSize.height * 0.3).rounded()))
                cover.frame = NSRect(x: 0, y: 0, width: scrollWidth, height: height)
                y = height + block.gap
                continue
            }
            var height = block.height
            if let editor = block.view as? TaskEditorView { height = editor.preferredHeight(width: contentWidth) }
            if let header = block.view as? ListHeaderView, header === projectHeader?.view { height = header.preferredHeight(width: contentWidth) }
            if let wide = block.view as? WideBlock { height = wide.preferredHeight(width: contentWidth) }
            let extra = (block.view as? CalendarEventsView)?.extendsLeft ?? 0
            block.view.frame = NSRect(x: x - extra, y: y, width: contentWidth + extra + (extra > 0 ? 3 : 0), height: height)
            block.view.needsLayout = true
            if let row = block.view as? TaskRowView, reorderableIDs.contains(row.task.id) {
                slots.append(.init(id: row.task.id, frame: block.view.frame, headingID: row.task.headingID, isHeading: false))
            } else if let heading = block.view as? HeadingRowView {
                slots.append(.init(id: heading.heading.id, frame: block.view.frame, headingID: nil, isHeading: true))
            }
            y += height + block.gap
        }

        documentView.slots = slots
        let total = max(y + 56, scrollView.contentSize.height)
        documentView.frame = NSRect(x: 0, y: 0, width: scrollWidth, height: total)
        documentView.needsLayout = true
    }

    private func refreshSelection() {
        for (id, view) in rowViews {
            if let row = view as? TaskRowView { row.isSelectedRow = selectedIDs.contains(id) }
            if let row = view as? HeadingRowView { row.isSelectedRow = selectedIDs.contains(id) }
            if let card = view as? BoardCardView { card.isSelectedCard = selectedIDs.contains(id) }
            if let row = view as? TableRowView { row.isSelectedRow = selectedIDs.contains(id) }
            if let row = view as? IdeaRowView { row.isSelectedRow = selectedIDs.contains(id) }
        }
        toolbar.setSelectionActive(!selectedIDs.isEmpty)
        toolbar.setEditing(openTaskID != nil)
        toolbar.setHeadingAvailable(canAddHeading)
    }

    private func scrollToRow(_ id: String) {
        guard let row = rowViews[id] else { return }
        var frame = row.superview == nil ? .zero : row.convert(row.bounds, to: documentView)
        if let editor, openTaskID == id { frame = frame == .zero ? editor.frame : frame.union(editor.frame) }
        documentView.scrollToVisible(frame.insetBy(dx: 0, dy: -8))
    }

    // MARK: - Header

    /// Notion-style cover above Today's title, or a hover "Add Cover" when there is none.
    private func appendCover(header: ListHeaderView) {
        guard searchQuery.isEmpty else { return }
        guard let spec = Preferences.todayCover else {
            let reveal = AddCoverReveal(frame: .zero)
            reveal.onAdd = { Preferences.todayCover = Covers.randomSpec() }
            reveal.trailingInset = header.actionWidth
            header.addSubview(reveal)
            return
        }
        let cover = coverView ?? CoverView(spec: spec, offset: Preferences.todayCoverOffset)
        cover.spec = spec
        cover.onChange = { Preferences.todayCover = $0 }
        cover.onOffset = { Preferences.todayCoverOffset = $0 }
        coverView = cover
        append(block: cover, height: 0, gap: 30)
    }

    private func updateHeader(for selection: Selection) {
        let store = TaskStore.shared
        switch selection {
        case .builtin(let list):
            let count = store.count(for: list)
            _ = count
            let subtitle = ""
            let header: ListHeaderView
            if list == .trash {
                header = ListHeaderView(title: list.title, subtitle: subtitle, notes: "", progress: nil,
                                        color: Theme.listColor(list), symbol: list.symbol,
                                        actionTitle: "Empty Trash", actionSymbol: "trash")
                header.onAction = { [weak self] in self?.emptyTrashAction(nil) }
            } else if list == .today {
                header = ListHeaderView(title: list.title, subtitle: subtitle, notes: "", progress: nil,
                                        color: Theme.listColor(list), symbol: list.symbol,
                                        actionTitle: "Plan My Day", actionSymbol: "waveform")
                header.onAction = { PlanDayWindowController.shared.show() }
            } else if list == .ideas {
                header = ListHeaderView(title: list.title, subtitle: subtitle, notes: "", progress: nil,
                                        color: Theme.listColor(list), symbol: list.symbol,
                                        actionTitle: "New Idea", actionSymbol: "plus")
                header.onAction = { [weak self] in self?.newIdea() }
            } else {
                header = ListHeaderView(title: list.title, subtitle: subtitle, notes: "",
                                        progress: nil, color: Theme.listColor(list), symbol: list.symbol)
            }
            if list == .today { appendCover(header: header) }
            append(block: header, height: 56, gap: 7)

        case .project(let id):
            guard let project = store.task(id) else { return }
            let progress = store.projectProgress(id)
            let ratio = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
            // Reuse the header while its notes are being typed so focus is never lost.
            if let kept = projectHeader, kept.id == id, kept.view.window?.firstResponder === kept.view.notesView {
                append(block: kept.view, height: kept.view.preferredHeight(width: contentWidth), gap: 18)
                return
            }
            let header = ListHeaderView(title: project.title, subtitle: "", notes: project.notes,
                                        progress: ratio, color: Theme.accent, showsNotes: true)
            header.onRing = { [weak self] in self?.completeProject(id) }
            header.onNotesChange = { notes in store.setNotes(id, notes) }
            header.onHeightChange = { [weak self] in self?.layoutBlocks() }
            projectHeader = (id, header)
            header.enableMenu()
            header.menuProvider = { [weak self] in self?.projectMenu(id) ?? NSMenu() }
            header.onTitleEdit = { current in
                if let title = Prompt.text(title: "Rename Project", message: "", placeholder: "Project", initial: current, button: "Rename") {
                    store.renameProject(id, to: title)
                }
            }
            let height = ListHeaderView.height(notes: project.notes, showsNotes: true, width: contentWidth)
            append(block: header, height: height, gap: 22)

        case .area(let id):
            guard let area = store.area(id) else { return }
            let projects = store.projects(inArea: id)
            _ = projects
            let header = ListHeaderView(title: area.title, subtitle: "", notes: "",
                                        progress: nil, color: Theme.success, symbol: "shippingbox")
            header.enableMenu()
            header.menuProvider = { [weak self] in self?.areaMenu(id) ?? NSMenu() }
            header.onTitleEdit = { current in
                if let title = Prompt.text(title: "Rename Area", message: "", placeholder: "Area", initial: current, button: "Rename") {
                    store.renameArea(id, to: title)
                }
            }
            append(block: header, height: 56, gap: 7)

        case .tag(let tag):
            let header = ListHeaderView(title: tag, subtitle: "", notes: "",
                                        progress: nil, color: Theme.accent, symbol: "tag")
            append(block: header, height: 56, gap: 14)
        }
    }

    private func openBrief(_ id: String) {
        editor?.commitAll()
        NotificationCenter.default.post(name: .openNotePage, object: id)
    }

    private func projectMenu(_ id: String) -> NSMenu {
        let store = TaskStore.shared
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Complete Project", symbol: "checkmark.circle") { [weak self] in self?.completeProject(id) })
        menu.addItem(ClosureMenuItem("When", symbol: "calendar") { [weak self] in
            guard let self, let header = self.projectHeader?.view else { return }
            WhenPicker.show(mode: .when, current: store.task(id)?.startDate, relativeTo: NSRect(x: 0, y: 0, width: 200, height: 40), of: header) { choice in
                choice.applyWhen(to: [id])
            }
        })
        menu.addItem(ClosureMenuItem("Add Tags", symbol: "tag") {
            if let value = Prompt.text(title: "Add Tags", message: "Separate tags with commas.", placeholder: "Tags",
                                       initial: store.task(id)?.tags.joined(separator: ", ") ?? "", button: "Save") {
                store.setTags(id, value.split(separator: ",").map { String($0) })
            }
        })
        menu.addItem(ClosureMenuItem("Add Deadline", symbol: "flag") { [weak self] in
            guard let self, let header = self.projectHeader?.view else { return }
            WhenPicker.show(mode: .deadline, current: store.task(id)?.deadline, relativeTo: NSRect(x: 0, y: 0, width: 200, height: 40), of: header) { choice in
                choice.applyDeadline(to: [id])
            }
        })
        menu.addItem(.separator())
        let moveItem = NSMenuItem(title: "Move", action: nil, keyEquivalent: "")
        moveItem.image = NSImage.symbol("arrow.right", size: 12, weight: .regular, color: Theme.secondary)
        let moveMenu = NSMenu()
        moveMenu.addItem(ClosureMenuItem("No Area", checked: store.task(id)?.areaID == nil) {
            if var p = store.task(id) { p.areaID = nil; store.update(p) }
        })
        for area in store.areas {
            moveMenu.addItem(ClosureMenuItem(area.title, checked: store.task(id)?.areaID == area.id) {
                if var p = store.task(id) { p.areaID = area.id; store.update(p) }
            })
        }
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)
        menu.addItem(ClosureMenuItem("Repeat…", symbol: "repeat") { TaskMenus.showRepeat(for: [id]) })
        menu.addItem(ClosureMenuItem("Duplicate Project", symbol: "plus.square.on.square") { store.duplicate(id) })
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        exportItem.image = NSImage.symbol("square.and.arrow.up", size: 12, weight: .regular, color: Theme.secondary)
        let exportMenu = NSMenu()
        exportMenu.addItem(ClosureMenuItem("Markdown…") { Exporter.exportMarkdown(.project(id)) })
        exportMenu.addItem(ClosureMenuItem("PDF…") { Exporter.exportPDF(.project(id)) })
        exportMenu.addItem(ClosureMenuItem("Print…") { Exporter.print(.project(id)) })
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        menu.addItem(ClosureMenuItem("Delete Project", symbol: "trash") {
            store.moveToTrash(id)
            self.state.selection = .builtin(.today)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open Notes as Page", symbol: "doc.text") { [weak self] in self?.openBrief(id) })
        return menu
    }

    private func areaMenu(_ id: String) -> NSMenu {
        let store = TaskStore.shared
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Section", symbol: "plus.square") { [weak self] in self?.newHeadingAction(nil) })
        menu.addItem(ClosureMenuItem("New Project in Area…", symbol: "plus") {
            if let title = Prompt.text(title: "New Project", message: "Name this project.", placeholder: "Project name") {
                let project = store.createProject(title: title, areaID: id)
                self.state.selection = .project(project.id)
            }
        })
        menu.addItem(ClosureMenuItem("Rename…", symbol: "pencil") {
            if let title = Prompt.text(title: "Rename Area", message: "", placeholder: "Area",
                                       initial: store.area(id)?.title ?? "", button: "Rename") {
                store.renameArea(id, to: title)
            }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete Area", symbol: "trash") {
            if Prompt.confirm(title: "Delete this area?", message: "Its projects and to-dos are kept.", button: "Delete") {
                store.deleteArea(id)
                self.state.selection = .builtin(.today)
            }
        })
        return menu
    }

    private func completeProject(_ id: String) {
        guard let project = TaskStore.shared.task(id) else { return }
        if project.isCompleted {
            TaskStore.shared.reopen(id)
            return
        }
        let open = TaskStore.shared.children(of: id).filter { $0.isTodo && $0.isOpen }.count
        let message = open > 0 ? "\(open) open to-do\(open == 1 ? "" : "s") will be completed as well." : "The project moves to the Logbook."
        guard Prompt.confirm(title: "Complete “\(project.title)”?", message: message, button: "Complete") else { return }
        TaskStore.shared.toggleCompletion(id)
    }

    private func headerSubtitle(for list: BuiltinList, count: Int) -> String {
        let countText = "\(count) to-\(count == 1 ? "do" : "dos")"
        if list == .today {
            let f = DateFormatter()
            f.dateFormat = "EEEE, MMMM d"
            return f.string(from: Date()) + "  ·  " + countText
        }
        return countText
    }

    private func title(for selection: Selection) -> String {
        switch selection {
        case .builtin(let list): return list.title
        case .project(let id): return TaskStore.shared.task(id)?.title ?? "Project"
        case .area(let id): return TaskStore.shared.area(id)?.title ?? "Area"
        case .tag(let tag): return "#" + tag
        }
    }

    private func emptyTitle(for selection: Selection) -> String {
        switch selection {
        case .builtin(.inbox): return "Inbox zero."
        case .builtin(.today): return "Nothing left for today."
        case .builtin(.upcoming): return "Nothing scheduled."
        case .builtin(.logbook): return "The Logbook is empty."
        case .builtin(.trash): return "Trash is empty."
        case .builtin(.ideas): return "No ideas yet."
        case .project: return "No to-dos yet."
        default: return "No to-dos here."
        }
    }

    private func emptySubtitle(for selection: Selection) -> String {
        switch selection {
        case .builtin(.inbox):
            return Preferences.aiEnabled ? "Add something below, press ⌃Space anywhere, or capture a thought with the AI sidebar."
                                         : "Add something below, or press ⌃Space from any app."
        case .builtin(.today): return "Move a to-do here with ⌘T, or enjoy the rest of the day."
        case .builtin(.upcoming): return "Give a to-do a start date and it will appear here."
        case .builtin(.logbook): return "Completed and canceled to-dos end up here."
        case .builtin(.ideas): return "Keep projects you haven't committed to here, with their notes and research. Press ⌘N for a new idea."
        case .project: return "Add to-dos below, or press ⇧⌘N for a heading."
        default: return "Anything you add shows up in this list."
        }
    }

    private func showsAddRow(for selection: Selection) -> Bool {
        switch selection {
        case .builtin(.logbook), .builtin(.trash): return false
        case .project(let id): return TaskStore.shared.task(id)?.isOpen ?? false
        default: return true
        }
    }

    private func canReorder(_ selection: Selection) -> Bool {
        switch selection {
        case .builtin(.logbook), .builtin(.trash), .builtin(.upcoming), .builtin(.ideas): return false
        default: return true
        }
    }

    // MARK: - Selection

    private func handleSelect(_ item: TaskItem, event: NSEvent) {
        view.window?.makeFirstResponder(documentView)
        let flags = event.modifierFlags
        if flags.contains(.command) {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
            anchorID = item.id
        } else if flags.contains(.shift), let anchor = anchorID,
                  let a = orderedIDs.firstIndex(of: anchor), let b = orderedIDs.firstIndex(of: item.id) {
            selectedIDs = Set(orderedIDs[min(a, b)...max(a, b)])
        } else {
            if openTaskID != nil && openTaskID != item.id { closeEditor() }
            selectedIDs = [item.id]
            anchorID = item.id
        }
        refreshSelection()
    }

    private var selectedOrdered: [String] { orderedIDs.filter { selectedIDs.contains($0) } }

    private func selectOnly(_ id: String?) {
        selectedIDs = id.map { [$0] } ?? []
        anchorID = id
        refreshSelection()
        if let id { scrollToRow(id) }
    }

    private func moveSelection(by delta: Int, extend: Bool, toEnd: Bool) {
        guard !orderedIDs.isEmpty else { return }
        let current = anchorID.flatMap { orderedIDs.firstIndex(of: $0) }
        var target: Int
        if toEnd {
            target = delta < 0 ? 0 : orderedIDs.count - 1
        } else if let current {
            target = max(0, min(orderedIDs.count - 1, current + delta))
        } else {
            target = delta < 0 ? orderedIDs.count - 1 : 0
        }
        let id = orderedIDs[target]
        if extend, let current {
            let last = selectedOrdered.last.flatMap { orderedIDs.firstIndex(of: $0) } ?? current
            let first = selectedOrdered.first.flatMap { orderedIDs.firstIndex(of: $0) } ?? current
            let edge = delta < 0 ? min(first, last) : max(first, last)
            let next = max(0, min(orderedIDs.count - 1, edge + delta))
            selectedIDs = Set(orderedIDs[min(current, next)...max(current, next)])
            refreshSelection()
            scrollToRow(orderedIDs[next])
        } else {
            if openTaskID != nil {
                openTaskID = nil
                selectedIDs = [id]
                anchorID = id
                rebuild(preserveScroll: true)
                scrollToRow(id)
            } else {
                selectOnly(id)
            }
        }
    }

    /// The full-page Markdown note for a to-do.
    private func openPage(for id: String) {
        guard let task = TaskStore.shared.task(id), task.isTodo || task.isProject || task.isIdea else { return }
        editor?.commitAll()
        selectedIDs = [id]
        anchorID = id
        refreshSelection()
        NotificationCenter.default.post(name: .openNotePage, object: id)
    }

    func focusList() {
        view.window?.makeFirstResponder(documentView)
        if let id = selectedOrdered.first { scrollToRow(id) }
    }

    private func openEditor(for id: String) {
        guard let task = TaskStore.shared.task(id), !task.isProject, !task.isHeading else { return }
        if wideLayout, searchQuery.isEmpty {
            selectOnly(id)
            if let view = rowViews[id] { TaskEditorPopover.show(taskID: id, from: view) }
            return
        }
        editor?.commitAll()
        openTaskID = id
        selectedIDs = [id]
        anchorID = id
        rebuild(preserveScroll: true)
        scrollToRow(id)
        if pendingFocus == nil { pendingFocus = .title; if let editor { DispatchQueue.main.async { editor.focus(.title) } } }
    }

    private func closeEditor() {
        guard let id = openTaskID else { return }
        editor?.commitAll()
        openTaskID = nil
        discardIfUntouched(id)
        rebuild(preserveScroll: true)
    }

    /// Like Things: a new to-do that was never given a title or notes disappears when closed.
    private func discardIfUntouched(_ id: String) {
        guard let task = TaskStore.shared.task(id), task.isTodo,
              task.title == "New To-Do" || task.title.isEmpty,
              task.notes.isEmpty, task.checklist.isEmpty, task.tags.isEmpty,
              Date().timeIntervalSince(task.createdAt) < 3600 else { return }
        TaskStore.shared.deletePermanently(id)
    }

    private func showContextMenu(for item: TaskItem, event: NSEvent) {
        if !selectedIDs.contains(item.id) {
            selectedIDs = [item.id]
            anchorID = item.id
            refreshSelection()
        }
        let menu = TaskMenus.context(for: selectedOrdered, selection: state.selection) { [weak self] in
            self?.rebuild(preserveScroll: true)
        }
        if let row = rowViews[item.id] {
            NSMenu.popUpContextMenu(menu, with: event, for: row)
        }
    }

    /// Things: dropping a file, web link or Mail message on a list makes a to-do that links to it.
    private func createLinkedTodos(_ items: [Links.Item], beforeID: String?, headingID: String?) {
        let store = TaskStore.shared
        var ids: [String] = []
        store.batch(items.count == 1 ? "Add Link" : "Add Links") {
            for item in items {
                let task = makeTask(title: item.title)
                store.setNotes(task.id, item.markdown)
                ids.append(task.id)
            }
        }
        rebuild(preserveScroll: true)
        if beforeID != nil || headingID != nil { handleDrop(ids: ids, beforeID: beforeID, headingID: headingID) }
        selectedIDs = Set(ids)
        refreshSelection()
    }

    private func handleDrop(ids: [String], beforeID: String?, headingID: String?) {
        let store = TaskStore.shared
        let moving = ids.filter { reorderableIDs.contains($0) }
        guard !moving.isEmpty else { return }
        var order = reorderableIDs.filter { !moving.contains($0) }
        if let beforeID, let index = order.firstIndex(of: beforeID) {
            order.insert(contentsOf: moving, at: index)
        } else {
            order.append(contentsOf: moving)
        }
        store.batch("Move") {
            if canAddHeading {
                for id in moving where store.task(id)?.isTodo == true && store.task(id)?.headingID != headingID {
                    store.setHeading(id, headingID: headingID)
                }
            }
            store.reorder(order)
        }
        selectedIDs = Set(moving)
        rebuild(preserveScroll: true)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey where !flags.contains(.command):
            moveSelection(by: -1, extend: flags.contains(.shift), toEnd: flags.contains(.option))
        case NSDownArrowFunctionKey where !flags.contains(.command):
            moveSelection(by: 1, extend: flags.contains(.shift), toEnd: flags.contains(.option))
        case 13, 3: // Return, Enter
            if flags.contains(.command) { quickEditSelected(nil) } else { openSelected(nil) }
        case 27: // Escape
            if openTaskID != nil {
                closeEditor()
            } else if !selectedIDs.isEmpty {
                selectedIDs.removeAll()
                anchorID = nil
                refreshSelection()
            } else {
                super.keyDown(with: event)
            }
        case 32 where flags.isEmpty: // Space
            if selectedIDs.isEmpty { focusQuickAdd() } else { newTaskBelow(nil) }
        case 127, NSDeleteFunctionKey: // Delete
            deleteSelected(nil)
        case 115 where flags.subtracting(.capsLock).isEmpty && !selectedTodoIDs.isEmpty && openTaskID == nil: // S
            showStatus(nil)
        case 112 where flags.subtracting(.capsLock).isEmpty && !selectedTodoIDs.isEmpty && openTaskID == nil: // P
            showPriority(nil)
        default:
            // Typing with the list focused starts a new to-do, so keystrokes are never lost.
            if flags.subtracting([.shift, .capsLock]).isEmpty, let text = event.characters, !text.isEmpty,
               text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) }),
               showsAddRow(for: state.selection), searchQuery.isEmpty {
                // Things' "type travel": typing opens Quick Find with what you typed.
                openQuickFind(initial: text)
                return
            }
            super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        selectedIDs = Set(orderedIDs)
        refreshSelection()
    }

    // MARK: - Menu actions (Item menu, context menu, toolbar)

    private var selectedTodoIDs: [String] {
        selectedOrdered.filter { TaskStore.shared.task($0)?.isTodo == true }
    }

    private func afterChange() {
        rebuild(preserveScroll: true)
    }

    @objc func openSelected(_ sender: Any?) {
        guard let id = selectedOrdered.first ?? openTaskID, let task = TaskStore.shared.task(id) else {
            focusQuickAdd()
            return
        }
        if task.isProject {
            state.selection = .project(task.id)
        } else if task.isIdea {
            openPage(for: task.id)
        } else if task.isHeading {
            if let title = Prompt.text(title: "Rename Heading", message: "", placeholder: "Heading", initial: task.title, button: "Rename") {
                TaskStore.shared.setTitle(task.id, title)
            }
        } else if openTaskID == id {
            closeEditor()
        } else {
            openEditor(for: id)
        }
    }

    /// The compact in-list editor (⌘↩), for quick date / tag changes without leaving the list.
    @objc func quickEditSelected(_ sender: Any?) {
        guard let id = selectedOrdered.first ?? anchorID, let task = TaskStore.shared.task(id), task.isTodo else { return }
        if openTaskID == id { closeEditor() } else { openEditor(for: id) }
    }

    @objc func newTaskBelow(_ sender: Any?) {
        let selection = state.selection
        if selection == .builtin(.ideas) { newIdea(); return }
        guard showsAddRow(for: selection) else { return }
        let anchor = selectedOrdered.last ?? openTaskID
        if let open = openTaskID { editor?.commitAll(); discardIfUntouched(open) }
        let anchorTask = anchor.flatMap { TaskStore.shared.task($0) }
        let task = makeTask(title: "New To-Do", afterTaskID: anchorTask == nil ? nil : anchor)
        // In a status view, a to-do added under a selected one joins its group.
        if reorderLocked, let anchorTask, anchorTask.isTodo, anchorTask.isOpen, anchorTask.stage != .todo, selection != .builtin(.active) {
            TaskStore.shared.setStage(task.id, anchorTask.stage)
        }
        present(newTaskID: task.id)
    }

    @objc func showStatus(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedTodoIDs
        guard !ids.isEmpty else { return }
        popUp(WorkflowMenus.status(for: ids) { [weak self] in self?.afterChange() }, from: sender)
    }

    @objc func showPriority(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedTodoIDs
        guard !ids.isEmpty else { return }
        popUp(WorkflowMenus.priority(for: ids) { [weak self] in self?.afterChange() }, from: sender)
    }

    @objc func showEstimate(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedTodoIDs
        guard !ids.isEmpty else { return }
        popUp(WorkflowMenus.estimate(for: ids) { [weak self] in self?.afterChange() }, from: sender)
    }

    @objc func newHeadingAction(_ sender: Any?) {
        var projectID: String? = nil
        var areaID: String? = nil
        switch state.selection {
        case .project(let id): projectID = id
        case .area(let id): areaID = id
        default:
            NSSound.beep()
            return
        }
        guard let title = Prompt.text(title: "New Section", message: "Sections group related to-dos.", placeholder: "Section name") else { return }
        let heading = TaskStore.shared.createHeading(title: title, projectID: projectID, areaID: areaID)
        if let anchor = selectedOrdered.last, reorderableIDs.contains(anchor) {
            var order = reorderableIDs
            if let index = order.firstIndex(of: anchor) { order.insert(heading.id, at: index + 1) }
            TaskStore.shared.reorder(order)
        }
        selectOnly(heading.id)
    }

    @objc func newChecklistAction(_ sender: Any?) {
        guard let id = openTaskID ?? selectedTodoIDs.first else { return }
        if openTaskID != id {
            pendingFocus = .checklist
            openEditor(for: id)
        } else {
            editor?.focus(.checklist)
        }
    }

    @objc func completeSelected(_ sender: Any?) {
        let ids = selectedOrdered.filter { TaskStore.shared.task($0)?.isHeading == false }
        guard !ids.isEmpty else { return }
        TaskStore.shared.batch("Complete") { for id in ids { TaskStore.shared.toggleCompletion(id) } }
        if let openTaskID, ids.contains(openTaskID) { self.openTaskID = nil }
        afterChange()
    }

    @objc func cancelSelected(_ sender: Any?) {
        let ids = selectedTodoIDs
        guard !ids.isEmpty else { return }
        TaskStore.shared.batch("Cancel") { for id in ids { TaskStore.shared.cancel(id) } }
        if let openTaskID, ids.contains(openTaskID) { self.openTaskID = nil }
        afterChange()
    }

    @objc func duplicateSelected(_ sender: Any?) {
        let ids = selectedOrdered.filter { TaskStore.shared.task($0)?.isHeading == false }
        guard !ids.isEmpty else { return }
        var copies: [String] = []
        TaskStore.shared.batch("Duplicate") {
            for id in ids { if let copy = TaskStore.shared.duplicate(id) { copies.append(copy.id) } }
        }
        selectedIDs = Set(copies)
        afterChange()
    }

    @objc func deleteSelected(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedOrdered
        guard !ids.isEmpty else { return }
        let next = nextSelection(after: ids)
        if case .builtin(.trash) = state.selection {
            let title = ids.count == 1 ? "Delete “\(TaskStore.shared.task(ids[0])?.title ?? "")” permanently?" : "Delete \(ids.count) items permanently?"
            guard Prompt.confirm(title: title, message: "This cannot be undone.", button: "Delete") else { return }
            for id in ids { TaskStore.shared.deletePermanently(id) }
        } else {
            TaskStore.shared.batch("Delete") { for id in ids { TaskStore.shared.moveToTrash(id) } }
        }
        openTaskID = nil
        selectedIDs = next.map { [$0] } ?? []
        anchorID = next
        afterChange()
    }

    private func nextSelection(after ids: [String]) -> String? {
        let remaining = orderedIDs.filter { !ids.contains($0) }
        guard let last = ids.last, let index = orderedIDs.firstIndex(of: last) else { return remaining.first }
        return orderedIDs[index...].first { remaining.contains($0) } ?? remaining.last
    }

    @objc func moveSelectedUp(_ sender: Any?) { nudge(-1) }
    @objc func moveSelectedDown(_ sender: Any?) { nudge(1) }

    private func nudge(_ delta: Int) {
        guard documentView.canReorder, let id = selectedOrdered.first, reorderableIDs.contains(id), selectedOrdered.count == 1 else { return }
        TaskStore.shared.nudge(id, in: reorderableIDs, by: delta)
        afterChange()
        scrollToRow(id)
    }

    @objc func startToday(_ sender: Any?) {
        let ids = selectedTodoIDs
        TaskStore.shared.batch("Today") { ids.forEach { TaskStore.shared.setBucket($0, bucket: .scheduled, date: Date().startOfDay) } }
        afterChange()
    }

    @objc func startEvening(_ sender: Any?) {
        let ids = selectedTodoIDs
        TaskStore.shared.batch("This Evening") { ids.forEach { TaskStore.shared.setEvening($0, true) } }
        afterChange()
    }

    @objc func startAnytime(_ sender: Any?) {
        let ids = selectedTodoIDs
        TaskStore.shared.batch("Anytime") { ids.forEach { TaskStore.shared.setBucket($0, bucket: .anytime) } }
        afterChange()
    }

    @objc func startSomeday(_ sender: Any?) {
        let ids = selectedTodoIDs
        TaskStore.shared.batch("Someday") { ids.forEach { TaskStore.shared.setBucket($0, bucket: .someday) } }
        afterChange()
    }

    @objc func startPlusDay(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftStart($0, days: 1) }; afterChange() }
    @objc func startMinusDay(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftStart($0, days: -1) }; afterChange() }
    @objc func startPlusWeek(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftStart($0, days: 7) }; afterChange() }
    @objc func startMinusWeek(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftStart($0, days: -7) }; afterChange() }
    @objc func deadlinePlusDay(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftDeadline($0, days: 1) }; afterChange() }
    @objc func deadlineMinusDay(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftDeadline($0, days: -1) }; afterChange() }
    @objc func deadlinePlusWeek(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftDeadline($0, days: 7) }; afterChange() }
    @objc func deadlineMinusWeek(_ sender: Any?) { selectedTodoIDs.forEach { TaskStore.shared.shiftDeadline($0, days: -7) }; afterChange() }

    private func popUp(_ menu: NSMenu, from sender: Any?) {
        if let button = sender as? NSView, button.window != nil {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        } else if let id = selectedOrdered.first, let row = rowViews[id], row.window != nil {
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: row.bounds.height), in: row)
        } else if let editor, editor.window != nil {
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 40), in: editor)
        }
    }

    /// Where to anchor a popover: the clicked button, else the selected row.
    private func anchor(for sender: Any?) -> (NSRect, NSView)? {
        if let button = sender as? NSView, button.window != nil, !(sender is NSMenuItem) { return (button.bounds, button) }
        if openTaskID != nil, let editor, editor.window != nil {
            return (NSRect(x: 40, y: 0, width: 160, height: 40), editor)
        }
        if let id = selectedOrdered.first, let row = rowViews[id], row.window != nil {
            return (NSRect(x: 0, y: 0, width: 160, height: row.bounds.height), row)
        }
        return nil
    }

    @objc func showWhen(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedTodoIDs
        guard !ids.isEmpty, let (rect, view) = anchor(for: sender) else { return }
        let current = ids.count == 1 ? TaskStore.shared.task(ids[0])?.startDate : nil
        let reminder = ids.count == 1 ? TaskStore.shared.task(ids[0])?.reminder : nil
        WhenPicker.show(mode: .when, current: current, reminder: reminder, relativeTo: rect, of: view) { [weak self] choice in
            choice.applyWhen(to: ids)
            self?.afterChange()
        }
    }

    @objc func showRemind(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedTodoIDs
        guard !ids.isEmpty, let (rect, view) = anchor(for: sender) else { return }
        let current = ids.count == 1 ? TaskStore.shared.task(ids[0])?.reminder : nil
        RemindPicker.show(current: current, relativeTo: rect, of: view) { [weak self] date in
            RemindPicker.apply(date, to: ids)
            self?.afterChange()
        }
    }

    @objc func showDeadline(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedTodoIDs
        guard !ids.isEmpty, let (rect, view) = anchor(for: sender) else { return }
        let current = ids.count == 1 ? TaskStore.shared.task(ids[0])?.deadline : nil
        WhenPicker.show(mode: .deadline, current: current, relativeTo: rect, of: view) { [weak self] choice in
            choice.applyDeadline(to: ids)
            self?.afterChange()
        }
    }

    @objc func showMoreMenu(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedOrdered
        guard !ids.isEmpty else { return }
        let menu = TaskMenus.context(for: ids, selection: state.selection) { [weak self] in self?.afterChange() }
        popUp(menu, from: sender)
    }

    @objc func showMove(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedOrdered.filter { TaskStore.shared.task($0)?.isHeading == false }
        guard !ids.isEmpty, let (rect, view) = anchor(for: sender) else { return }
        SearchListPopover.show(.move(ids: ids) { [weak self] in self?.afterChange() }, relativeTo: rect, of: view)
    }

    @objc func showTags(_ sender: Any?) {
        let ids = openTaskID.map { [$0] } ?? selectedTodoIDs
        guard !ids.isEmpty, let (rect, view) = anchor(for: sender) else { return }
        SearchListPopover.show(.tags(ids: ids) { [weak self] in self?.afterChange() }, relativeTo: rect, of: view)
    }

    @objc func showRepeat(_ sender: Any?) {
        let ids = selectedTodoIDs
        guard !ids.isEmpty else { return }
        TaskMenus.showRepeat(for: ids) { [weak self] in self?.afterChange() }
    }

    @objc func openNote(_ sender: Any?) {
        guard let id = openTaskID ?? selectedTodoIDs.first else { return }
        openPage(for: id)
    }

    @objc func startFocusTimer(_ sender: Any?) {
        guard let id = openTaskID ?? selectedTodoIDs.first else { return }
        FocusTimer.shared.start(taskID: id)
    }

    @objc func showInList(_ sender: Any?) {
        guard let id = selectedOrdered.first else { return }
        NotificationCenter.default.post(name: .openTask, object: id)
    }

    @objc func emptyTrashAction(_ sender: Any?) {
        let count = TaskStore.shared.count(for: .trash)
        guard count > 0 else { return }
        guard Prompt.confirm(title: "Empty the Trash?", message: "\(count) item\(count == 1 ? "" : "s") will be deleted permanently.", button: "Empty Trash") else { return }
        TaskStore.shared.emptyTrash()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        // While typing, ⌘⌫ / ⌘↑ / ⌘↓ / ⌘← belong to the text field.
        if view.window?.firstResponder is NSTextView,
           [#selector(deleteSelected(_:)), #selector(moveSelectedUp(_:)), #selector(moveSelectedDown(_:))].contains(action) {
            return false
        }
        let hasSelection = !selectedIDs.isEmpty
        let hasTodos = !selectedTodoIDs.isEmpty
        switch action {
        case #selector(newTaskBelow(_:)):
            return showsAddRow(for: state.selection)
        case #selector(newHeadingAction(_:)):
            return canAddHeading
        case #selector(emptyTrashAction(_:)):
            return TaskStore.shared.count(for: .trash) > 0
        case #selector(openSelected(_:)), #selector(quickEditSelected(_:)), #selector(deleteSelected(_:)), #selector(showMove(_:)),
             #selector(duplicateSelected(_:)), #selector(completeSelected(_:)):
            return hasSelection
        case #selector(moveSelectedUp(_:)), #selector(moveSelectedDown(_:)):
            return selectedIDs.count == 1 && documentView.canReorder
        case #selector(showInList(_:)):
            if case .builtin = state.selection { return hasSelection }
            return false
        case #selector(newChecklistAction(_:)), #selector(openNote(_:)):
            return hasTodos || openTaskID != nil
        default:
            return hasTodos
        }
    }

    // MARK: - New task

    @discardableResult
    private func makeTask(title: String, afterTaskID: String? = nil) -> TaskItem {
        let store = TaskStore.shared
        var anchorTask: TaskItem? = nil
        if let afterTaskID, let candidate = store.task(afterTaskID), candidate.isTodo { anchorTask = candidate }
        switch state.selection {
        case .builtin(let list):
            switch list {
            case .inbox:
                return store.createTask(title: title, bucket: .inbox, afterTaskID: anchorTask?.id)
            case .today:
                return store.createTask(title: title, bucket: .scheduled, startDate: Date().startOfDay,
                                        projectID: anchorTask?.projectID, areaID: anchorTask?.areaID,
                                        isEvening: anchorTask?.isEvening ?? false, afterTaskID: anchorTask?.id)
            case .upcoming:
                return store.createTask(title: title, bucket: .scheduled, startDate: anchorTask?.startDate ?? Date().startOfDay.addingDays(1),
                                        afterTaskID: anchorTask?.id)
            case .anytime:
                return store.createTask(title: title, bucket: .anytime, projectID: anchorTask?.projectID,
                                        areaID: anchorTask?.areaID, afterTaskID: anchorTask?.id)
            case .someday:
                return store.createTask(title: title, bucket: .someday, projectID: anchorTask?.projectID,
                                        areaID: anchorTask?.areaID, afterTaskID: anchorTask?.id)
            case .logbook, .trash:
                return store.createTask(title: title, bucket: .inbox)
            case .ideas:
                return store.createIdea(title: title)
            case .active:
                let task = store.createTask(title: title, bucket: .anytime, projectID: anchorTask?.projectID,
                                            areaID: anchorTask?.areaID, afterTaskID: anchorTask?.id)
                store.setStage(task.id, .progress)
                return store.task(task.id) ?? task
            }
        case .project(let id):
            let project = store.task(id)
            var headingID = anchorTask?.headingID
            if let anchor = afterTaskID, store.task(anchor)?.isHeading == true { headingID = anchor }
            return store.createTask(title: title, bucket: .anytime, projectID: id, areaID: project?.areaID,
                                    headingID: headingID, afterTaskID: anchorTask?.id)
        case .area(let id):
            var headingID = anchorTask?.headingID
            if let anchor = afterTaskID, store.task(anchor)?.isHeading == true { headingID = anchor }
            return store.createTask(title: title, bucket: .anytime, areaID: id, headingID: headingID, afterTaskID: anchorTask?.id)
        case .tag(let tag):
            return store.createTask(title: title, bucket: .inbox, tags: [tag])
        }
    }
}

// MARK: - UI test hooks (used by --uitest only)

extension ListViewController {
    var debugAddField: NSTextField? { addRow?.field }
    var debugDocumentView: NSView { documentView }
    var debugSelectedIDs: Set<String> { selectedIDs }
    var debugOrderedIDs: [String] { orderedIDs }
    var debugOpenTaskID: String? { openTaskID }
}

extension ListViewController {
    func debugSelect(_ id: String) {
        selectedIDs = [id]
        anchorID = id
        refreshSelection()
    }
}
