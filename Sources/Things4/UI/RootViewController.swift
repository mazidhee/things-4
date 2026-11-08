import AppKit

final class RootViewController: NSViewController {
    let state: AppState

    init(state: AppState) {
        self.state = state
        self.sidebarVC = SidebarViewController(state: state)
        self.listVC = ListViewController(state: state)
        self.noteVC = NotePageViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let sidebarContainer = FillView(fill: Theme.sidebar)
    private let contentContainer = FillView(fill: Theme.window)
    private let aiContainer = FillView(fill: Theme.panel)
    private let separator = FillView(fill: Theme.separator)

    let sidebarVC: SidebarViewController
    let listVC: ListViewController
    let noteVC: NotePageViewController
    private let aiVC = AIPanelViewController()

    private var aiWidth: NSLayoutConstraint!
    private var sidebarWidth: NSLayoutConstraint!

    override func loadView() {
        let root = FillView(fill: Theme.window)
        view = root

        root.addSubview(sidebarContainer)
        root.addSubview(separator)
        root.addSubview(contentContainer)
        root.addSubview(aiContainer)

        for container in [sidebarContainer, separator, contentContainer, aiContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
        }

        aiWidth = aiContainer.widthAnchor.constraint(equalToConstant: 0)
        sidebarWidth = sidebarContainer.widthAnchor.constraint(equalToConstant: Preferences.sidebarVisible ? Layout.sidebarWidth : 0)

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            separator.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: aiContainer.leadingAnchor),

            aiContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            aiContainer.topAnchor.constraint(equalTo: root.topAnchor),
            aiContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            aiWidth
        ])

        addChild(sidebarVC)
        addChild(listVC)
        addChild(noteVC)
        addChild(aiVC)

        sidebarContainer.addSubviewPinned(sidebarVC.view)
        contentContainer.addSubviewPinned(listVC.view)
        contentContainer.addSubviewPinned(noteVC.view)
        noteVC.view.isHidden = true
        aiContainer.addSubviewPinned(aiVC.view)
        aiContainer.isHidden = true
        sidebarContainer.clipsToBounds = true

        aiVC.onClose = { [weak self] in self?.setAIPanel(visible: false) }

        NotificationCenter.default.addObserver(self, selector: #selector(toggleAI), name: .aiPanelToggle, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleSidebar), name: .sidebarToggle, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .preferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openNote(_:)), name: .openNotePage, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(closeNote), name: .closeNotePage, object: noteVC)
        NotificationCenter.default.addObserver(self, selector: #selector(closeNote), name: .selectionDidChange, object: state)
    }

    var isShowingNote: Bool { !noteVC.view.isHidden }

    private var isFrontmost: Bool {
        (MainWindowController.active ?? MainWindowController.shared).root === self
    }

    @objc private func openNote(_ notification: Notification) {
        guard let id = notification.object as? String, isFrontmost else { return }
        noteVC.show(taskID: id, returnTo: state.selection)
        noteVC.view.isHidden = false
        listVC.view.isHidden = true
        view.window?.makeKeyAndOrderFront(nil)
        noteVC.focusInitial()
    }

    @objc func closeNote() {
        guard isShowingNote else { return }
        noteVC.save()
        noteVC.view.isHidden = true
        listVC.view.isHidden = false
        listVC.focusList()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func preferencesChanged() {
        if !Preferences.aiEnabled, state.isAIPanelVisible {
            setAIPanel(visible: false)
        }
    }

    @objc private func toggleAI() {
        guard Preferences.aiEnabled else { return }
        setAIPanel(visible: !state.isAIPanelVisible)
    }

    @objc func toggleSidebar() {
        let visible = !Preferences.sidebarVisible
        Preferences.sidebarVisible = visible
        sidebarWidth.constant = visible ? Layout.sidebarWidth : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }

    private func setAIPanel(visible: Bool) {
        state.isAIPanelVisible = visible
        if visible { aiContainer.isHidden = false }
        aiWidth.constant = visible ? 376 : 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            guard let self else { return }
            if !visible { self.aiContainer.isHidden = true }
            if visible { self.aiVC.focusComposer() }
        }
    }

    func select(_ selection: Selection) {
        state.selection = selection
    }
}
