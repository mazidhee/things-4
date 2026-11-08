import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(backToList) {
            let controller = MainWindowController.active ?? .shared
            return controller.root.isShowingNote && !(controller.window?.firstResponder is NSTextView)
        }
        return true
    }

    private var aiMenuItem: NSMenuItem?
    private var appearanceItems: [AppearanceMode: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        MainWindowController.shared.showWindow(nil)
        MainWindowController.shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = QuickEntryWindowController.shared
        ReminderService.shared.start()
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { PhoneReminders.shared.start() }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) || ProcessInfo.processInfo.environment["THINGS4_API_PORT"] != nil {
            APIServer.shared.refresh()
        }
        if !CommandLine.arguments.contains("--snapshot") { MenuBarController.shared.start() }
        if let i = CommandLine.arguments.firstIndex(of: "--feature-check"), CommandLine.arguments.count > i + 1 {
            // Test hook: export a project to Markdown + PDF and render the menu bar popover with a running timer.
            let dir = CommandLine.arguments[i + 1]
            if let project = TaskStore.shared.tasks.filter({ $0.isProject && $0.isOpen }).max(by: { TaskStore.shared.children(of: $0.id).count < TaskStore.shared.children(of: $1.id).count }) {
                try? Exporter.markdown(for: .project(project.id)).text.write(toFile: dir + "/export.md", atomically: true, encoding: .utf8)
                Exporter.writePDF(.project(project.id), to: URL(fileURLWithPath: dir + "/export.pdf"))
            }
            if let task = TaskStore.shared.tasks(in: .builtin(.today)).first {
                FocusTimer.shared.start(taskID: task.id, minutes: 25)
                FocusTimer.shared.addMinutes(0)
            }
            let list = MenuBarListViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = list
            list.reload()
            window.setContentSize(list.preferredContentSize)
            window.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/menubar.png"))
                }
                let gallery = CoverGalleryViewController(current: "gradient:2") { _ in }
                let galleryWindow = NSWindow(contentViewController: gallery)
                galleryWindow.appearance = NSAppearance(named: .darkAqua)
                galleryWindow.orderFront(nil)
                galleryWindow.contentView?.layoutSubtreeIfNeeded()
                if let view = galleryWindow.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/gallery.png"))
                }
                FocusTimer.shared.stop()
                NSApp.terminate(nil)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--open-url"), CommandLine.arguments.count > i + 1,
           let url = URL(string: CommandLine.arguments[i + 1]) {
            // Test hook: run a things4:// link without going through Launch Services.
            URLCommands.handle(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--reminder-delivered") {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                    print("auth=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) style=\(settings.alertStyle.rawValue) delivered=\(delivered.map { "\($0.request.content.title) @ \($0.date)" })")
                    fflush(stdout)
                    exit(0)
                }
            }
        }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { CalendarService.shared.requestIfNeeded() }
        if CommandLine.arguments.contains("--calendar-check") {
            let service = CalendarService.shared
            print("calendar status=\(service.status.rawValue) hasAccess=\(service.hasAccess) enabled=\(Preferences.calendarsEnabled)")
            for (source, calendars) in service.calendarsBySource() { print("  \(source): \(calendars.map(\.title))") }
            for offset in 0..<7 {
                let day = Date().startOfDay.addingDays(offset)
                print("  day+\(offset): \(service.events(on: day).map { "\($0.isAllDay ? "all-day" : "\($0.start)") \($0.title)" })")
            }
            NSApp.terminate(nil)
        }
        if CommandLine.arguments.contains("--reminder-check") {
            // Test hook: set a reminder 70 s ahead on the first open to-do, then list what macOS has queued.
            if let task = TaskStore.shared.tasks.first(where: { $0.isTodo && $0.isOpen }) {
                TaskStore.shared.setReminder(task.id, at: Date().addingTimeInterval(20))
            }
            ReminderService.shared.requestAuthorization { granted in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
                        print("authorized=\(granted) pending=\(pending.map { "\($0.content.title) @ \(($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate().map { "\($0)" } ?? "?")" })")
                        fflush(stdout)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                                print("delivered=\(delivered.map { "\($0.request.content.title) @ \($0.date)" })")
                                fflush(stdout)
                                exit(0)
                            }
                        }
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(updateBadge), name: .storeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .preferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dayChanged), name: .NSCalendarDayChanged, object: nil)
        updateBadge()
        if CommandLine.arguments.contains("--uitest") { UITest.run() }

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "snapshot.png"
            if CommandLine.arguments.contains("--snapshot-ai") {
                NotificationCenter.default.post(name: .aiPanelToggle, object: nil)
            }
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot-demo"),
               CommandLine.arguments.count > index + 1 {
                let destination = CommandLine.arguments[index + 1]
                NotificationCenter.default.post(name: .aiPanelToggle, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    NotificationCenter.default.post(name: .aiDemo, object: destination)
                }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot-select"), CommandLine.arguments.count > index + 1 {
                let name = CommandLine.arguments[index + 1]
                if let list = BuiltinList(rawValue: name) { AppState.shared.selection = .builtin(list) }
                else if let area = TaskStore.shared.areas.first(where: { $0.title == name }) { AppState.shared.selection = .area(area.id) }
                else if let project = TaskStore.shared.tasks.first(where: { $0.isProject && $0.title == name }) { AppState.shared.selection = .project(project.id) }
            }
            if CommandLine.arguments.contains("--snapshot-project"),
               let project = TaskStore.shared.tasks.first(where: { $0.isProject }) {
                AppState.shared.selection = .project(project.id)
            }
            if CommandLine.arguments.contains("--snapshot-editor") {
                let today = TaskStore.shared.tasks(in: .builtin(.today))
                if let task = today.first(where: { !$0.checklist.isEmpty }) ?? today.first {
                    NotificationCenter.default.post(name: .openTask, object: task.id, userInfo: ["edit": true])
                }
            }
            if CommandLine.arguments.contains("--snapshot-settings") {
                SettingsWindowController.shared.showWindow(nil)
            }
            if CommandLine.arguments.contains("--snapshot-page"),
               let task = TaskStore.shared.tasks.first(where: { $0.isTodo && $0.isOpen && !$0.notes.isEmpty }) ?? TaskStore.shared.tasks.first(where: { $0.isTodo }) {
                NotificationCenter.default.post(name: .openNotePage, object: task.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.writeSnapshot(path)
                if CommandLine.arguments.contains("--snapshot-settings") {
                    self.writeSettingsSnapshot(path.replacingOccurrences(of: ".png", with: "-settings.png"))
                }
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func dayChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .storeDidChange, object: nil)
        }
    }

    @objc private func preferencesChanged() {
        aiMenuItem?.isHidden = !Preferences.aiEnabled
        for (mode, item) in appearanceItems {
            item.state = mode == Preferences.appearance ? .on : .off
        }
        updateBadge()
        if APIServer.shared.isManaged { APIServer.shared.refresh() }
    }

    @objc private func updateBadge() {
        let count = Preferences.showDockBadge ? TaskStore.shared.todayBadgeCount : 0
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func writeSnapshot(_ path: String) {
        guard let window = MainWindowController.shared.window,
              let view = window.contentView else { return }
        window.makeFirstResponder(nil)
        let env = ProcessInfo.processInfo.environment
        let size = NSSize(width: Double(env["THINGS4_SNAP_W"] ?? "") ?? 1240, height: Double(env["THINGS4_SNAP_H"] ?? "") ?? 800)
        window.setContentSize(size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func writeSettingsSnapshot(_ path: String) {
        guard let view = SettingsWindowController.shared.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // Keep running in the Dock with the window closed, like Things. Quick Entry
    // still works and clicking the Dock icon brings the window back.
    /// things4:///add?title=… and friends (see URLCommands).
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(URLCommands.handle)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.shared.showWindow(nil) }
        return true
    }

    // MARK: - Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let backspace = "\u{8}"

        // Things 4
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(item("About Things 4", #selector(showAbout), target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Things 4", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Things 4", #selector(NSApplication.terminate(_:)), "q"))

        // File
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(item("New To-Do", #selector(newTask), "n", target: self))
        fileMenu.addItem(item("New Repeating To-Do", #selector(newRepeatingTask), target: self))
        fileMenu.addItem(item("New Project", #selector(newProject), "n", [.command, .option], target: self))
        fileMenu.addItem(item("New Heading", #selector(ListViewController.newHeadingAction(_:)), "n", [.command, .shift]))
        fileMenu.addItem(item("New Area", #selector(newArea), target: self))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Quick Entry", #selector(quickEntry), " ", [.control], target: self))
        fileMenu.addItem(.separator())
        let exportMenu = NSMenu(title: "Export")
        exportMenu.addItem(item("Markdown…", #selector(exportMarkdown), target: self))
        exportMenu.addItem(item("PDF…", #selector(exportPDF), "e", [.command, .shift, .option], target: self))
        let exportItem = NSMenuItem(title: "Export List", action: nil, keyEquivalent: "")
        exportItem.submenu = exportMenu
        fileMenu.addItem(exportItem)
        fileMenu.addItem(item("Print…", #selector(printList), "p", target: self))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Empty Trash…", #selector(ListViewController.emptyTrashAction(_:))))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))

        // Edit
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(item("Undo", #selector(undoAction), "z", target: self))
        editMenu.addItem(item("Redo", #selector(redoAction), "z", [.command, .shift], target: self))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Duplicate", #selector(ListViewController.duplicateSelected(_:)), "d"))
        editMenu.addItem(item("Delete", #selector(ListViewController.deleteSelected(_:)), backspace))

        // Item
        let itemItem = NSMenuItem()
        mainMenu.addItem(itemItem)
        let itemMenu = NSMenu(title: "Item")
        itemItem.submenu = itemMenu
        itemMenu.addItem(item("Open", #selector(ListViewController.openSelected(_:))))
        itemMenu.addItem(item("Quick Edit", #selector(ListViewController.quickEditSelected(_:))))
        itemMenu.addItem(item("New To-Do Below", #selector(ListViewController.newTaskBelow(_:))))
        itemMenu.addItem(item("New Checklist", #selector(ListViewController.newChecklistAction(_:)), "c", [.command, .shift]))
        itemMenu.addItem(item("Open as Page", #selector(ListViewController.openNote(_:)), "o", [.command, .option]))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Mark as Completed", #selector(ListViewController.completeSelected(_:)), "k"))
        itemMenu.addItem(item("Mark as Canceled", #selector(ListViewController.cancelSelected(_:)), "k", [.command, .option]))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("When…", #selector(ListViewController.showWhen(_:)), "s"))
        itemMenu.addItem(item("Today", #selector(ListViewController.startToday(_:)), "t"))
        itemMenu.addItem(item("This Evening", #selector(ListViewController.startEvening(_:)), "e"))
        itemMenu.addItem(item("Anytime", #selector(ListViewController.startAnytime(_:)), "r"))
        itemMenu.addItem(item("Someday", #selector(ListViewController.startSomeday(_:)), "o"))
        itemMenu.addItem(item("Start Date +1 Day", #selector(ListViewController.startPlusDay(_:)), "]", [.control]))
        itemMenu.addItem(item("Start Date −1 Day", #selector(ListViewController.startMinusDay(_:)), "[", [.control]))
        itemMenu.addItem(item("Start Date +1 Week", #selector(ListViewController.startPlusWeek(_:)), "]", [.control, .shift]))
        itemMenu.addItem(item("Start Date −1 Week", #selector(ListViewController.startMinusWeek(_:)), "[", [.control, .shift]))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Deadline…", #selector(ListViewController.showDeadline(_:)), "d", [.command, .shift]))
        itemMenu.addItem(item("Remind Me…", #selector(ListViewController.showRemind(_:)), "r", [.command, .option]))
        itemMenu.addItem(item("Deadline +1 Day", #selector(ListViewController.deadlinePlusDay(_:)), ".", [.control]))
        itemMenu.addItem(item("Deadline −1 Day", #selector(ListViewController.deadlineMinusDay(_:)), ",", [.control]))
        itemMenu.addItem(item("Deadline +1 Week", #selector(ListViewController.deadlinePlusWeek(_:)), ".", [.control, .shift]))
        itemMenu.addItem(item("Deadline −1 Week", #selector(ListViewController.deadlineMinusWeek(_:)), ",", [.control, .shift]))
        itemMenu.addItem(item("Repeat…", #selector(ListViewController.showRepeat(_:)), "r", [.command, .shift]))
        itemMenu.addItem(item("Start Focus Timer", #selector(ListViewController.startFocusTimer(_:)), "p", [.control, .command]))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Move…", #selector(ListViewController.showMove(_:)), "m", [.command, .shift]))
        itemMenu.addItem(item("Tags…", #selector(ListViewController.showTags(_:)), "t", [.command, .shift]))
        itemMenu.addItem(item("Show in List", #selector(ListViewController.showInList(_:)), "l"))
        itemMenu.addItem(.separator())
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Back to List", #selector(backToList), String(UnicodeScalar(NSLeftArrowFunctionKey)!), target: self))
        itemMenu.addItem(item("Move Up", #selector(ListViewController.moveSelectedUp(_:)), up))
        itemMenu.addItem(item("Move Down", #selector(ListViewController.moveSelectedDown(_:)), down))

        // View
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let lists: [(String, BuiltinList, String)] = [
            ("Inbox", .inbox, "1"), ("Today", .today, "2"), ("Upcoming", .upcoming, "3"),
            ("Anytime", .anytime, "4"), ("Someday", .someday, "5"), ("Logbook", .logbook, "6")
        ]
        for (title, list, key) in lists {
            let entry = item(title, #selector(selectList(_:)), key, target: self)
            entry.representedObject = list.rawValue
            viewMenu.addItem(entry)
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Quick Find", #selector(focusSearch), "f", target: self))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Show/Hide Sidebar", #selector(toggleSidebar), "/", target: self))
        let ai = item("Show/Hide AI Sidebar", #selector(toggleAI), "a", [.command, .shift], target: self)
        ai.isHidden = !Preferences.aiEnabled
        aiMenuItem = ai
        viewMenu.addItem(ai)
        viewMenu.addItem(.separator())
        let appearanceMenu = NSMenu(title: "Appearance")
        for mode in AppearanceMode.allCases {
            let entry = item(mode.title, #selector(setAppearance(_:)), target: self)
            entry.representedObject = mode.rawValue
            entry.state = mode == Preferences.appearance ? .on : .off
            appearanceMenu.addItem(entry)
            appearanceItems[mode] = entry
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        viewMenu.addItem(appearanceItem)

        // Window
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("New Window", #selector(newWindow), "n", [.control, .command], target: self))
        windowMenu.addItem(item("Tags…", #selector(showTagManager), "t", [.control, .command], target: self))
        windowMenu.addItem(item("Things 4", #selector(showMainWindow), "0", target: self))
        NSApp.windowsMenu = windowMenu

        // Help
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(item("Keyboard Shortcuts", #selector(showShortcuts), "/", [.command, .shift], target: self))
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
        routeListActions(in: mainMenu)
    }

    /// Item-menu style actions go straight to the list controller instead of
    /// hunting through the responder chain, so they work wherever focus is.
    private func routeListActions(in menu: NSMenu) {
        let list = MainWindowController.shared.root.listVC
        for entry in menu.items {
            if let submenu = entry.submenu { routeListActions(in: submenu) }
            guard entry.target == nil, let action = entry.action,
                  list.responds(to: action), !NSResponder.instancesRespond(to: action) else { continue }
            entry.target = ListActionRouter.shared
        }
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(string: """
        A free, open-source task manager for macOS.

        Native AppKit. Local SQLite database. AI features are optional and use the provider and key you choose in Settings.

        Released under the MIT license.
        """, attributes: [.font: Fonts.regular(11), .foregroundColor: Theme.secondary])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Things 4",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1",
            .credits: credits
        ])
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func exportMarkdown() { Exporter.exportMarkdown(AppState.shared.selection) }
    @objc private func exportPDF() { Exporter.exportPDF(AppState.shared.selection) }
    @objc private func printList() { Exporter.print(AppState.shared.selection) }

    @objc private func showTagManager() {
        TagManagerWindowController.shared.showWindow(nil)
        TagManagerWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func newWindow() {
        MainWindowController.openNew(selection: AppState.shared.selection)
    }

    @objc private func showMainWindow() {
        MainWindowController.shared.showWindow(nil)
        MainWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func newTask() {
        showMainWindow()
        NotificationCenter.default.post(name: .newTask, object: nil)
    }

    @objc private func newProject() {
        showMainWindow()
        guard let title = Prompt.text(title: "New Project", message: "Name this project.", placeholder: "Project name") else { return }
        var areaID: String? = nil
        if case .area(let id) = AppState.shared.selection { areaID = id }
        if case .project(let id) = AppState.shared.selection { areaID = TaskStore.shared.task(id)?.areaID }
        let project = TaskStore.shared.createProject(title: title, areaID: areaID)
        AppState.shared.selection = .project(project.id)
    }

    @objc private func newRepeatingTask() {
        showMainWindow()
        guard let title = Prompt.text(title: "New Repeating To-Do", message: "Name the to-do, then choose how often it repeats.", placeholder: "To-do") else { return }
        let task = TaskStore.shared.createTask(title: title, bucket: .scheduled, startDate: Date().startOfDay)
        TaskMenus.showRepeat(for: [task.id])
        if TaskStore.shared.task(task.id)?.repeatRule == nil {
            TaskStore.shared.setRepeat(task.id, rule: RepeatRule(frequency: .daily))
        }
    }

    @objc private func newArea() {
        showMainWindow()
        guard let title = Prompt.text(title: "New Area", message: "Name this area.", placeholder: "Area name") else { return }
        let area = TaskStore.shared.createArea(title: title)
        AppState.shared.selection = .area(area.id)
    }

    /// Text fields keep their own typing undo; everything else undoes store changes,
    /// even if the main window is not key at that moment.
    @objc private func undoAction() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true, text.undoManager !== TaskStore.shared.undoManager {
            text.undoManager?.undo()
        } else if TaskStore.shared.undoManager.canUndo {
            TaskStore.shared.undoManager.undo()
        }
    }

    @objc private func redoAction() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true, text.undoManager !== TaskStore.shared.undoManager {
            text.undoManager?.redo()
        } else if TaskStore.shared.undoManager.canRedo {
            TaskStore.shared.undoManager.redo()
        }
    }

    @objc func backToList() {
        (MainWindowController.active ?? .shared).root.closeNote()
    }

    @objc private func quickEntry() {
        QuickEntryWindowController.shared.show()
    }

    @objc private func toggleAI() {
        NotificationCenter.default.post(name: .aiPanelToggle, object: nil)
    }

    @objc private func toggleSidebar() {
        NotificationCenter.default.post(name: .sidebarToggle, object: nil)
    }

    @objc private func setAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AppearanceMode(rawValue: raw) else { return }
        Preferences.appearance = mode
    }

    @objc private func selectList(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let list = BuiltinList(rawValue: raw) else { return }
        showMainWindow()
        AppState.shared.selection = .builtin(list)
    }

    @objc private func focusSearch() {
        showMainWindow()
        NotificationCenter.default.post(name: .focusSearch, object: nil)
    }

    @objc private func showShortcuts() {
        ShortcutsWindowController.shared.showWindow(nil)
        ShortcutsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Shared prompts

enum Prompt {
    static func text(title: String, message: String, placeholder: String, initial: String = "",
                     button: String = "Create") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        restoreFocus()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// NSAlert does not always hand key status back to the main window, which
    /// leaves every keyboard shortcut dead until the user clicks the window.
    static func restoreFocus() {
        DispatchQueue.main.async {
            let controller = MainWindowController.active ?? .shared
            guard let window = controller.window, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            if window.firstResponder === window || window.firstResponder == nil {
                controller.root.listVC.focusList()
            }
        }
    }

    static func confirm(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        restoreFocus()
        return response == .alertFirstButtonReturn
    }
}

// MARK: - Keyboard shortcuts window

final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.window
        window.center()
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let window else { return }
        let sections: [(String, [(String, String)])] = [
            ("Create", [("New To-Do", "⌘N"), ("New To-Do Below", "Space"), ("New Project", "⌥⌘N"),
                        ("New Heading", "⇧⌘N"), ("New Checklist", "⇧⌘C"), ("Quick Entry", "⌃Space"), ("Quick Entry with Autofill", "⌃⌥Space"), ("Remind Me", "⌥⌘R")]),
            ("Edit", [("Open page", "↩  or double-click"), ("Quick edit in list", "⌘↩"), ("Back to list", "Esc  or  ⌘←"), ("Complete", "⌘K"), ("Cancel", "⌥⌘K"),
                      ("Duplicate", "⌘D"), ("Delete", "⌘⌫"), ("Undo", "⌘Z"), ("Tags", "⇧⌘T"), ("Repeat", "⇧⌘R")]),
            ("Dates", [("When", "⌘S"), ("Today", "⌘T"), ("This Evening", "⌘E"), ("Anytime", "⌘R"), ("Someday", "⌘O"),
                       ("Start ±1 day", "⌃]  ⌃["), ("Start ±1 week", "⌃⇧]  ⌃⇧["), ("Deadline", "⇧⌘D"),
                       ("Deadline ±1 day", "⌃.  ⌃,"), ("Deadline ±1 week", "⌃⇧.  ⌃⇧,")]),
            ("Move & select", [("Move to list", "⇧⌘M"), ("Show in List", "⌘L"), ("Move Up / Down", "⌘↑  ⌘↓"),
                               ("Select", "↑  ↓"), ("Extend selection", "⇧↑  ⇧↓"), ("Select All", "⌘A")]),
            ("Navigate", [("Inbox … Logbook", "⌘1 … ⌘6"), ("Quick Find", "⌘F"), ("Show/Hide Sidebar", "⌘/"),
                          ("Show/Hide AI Sidebar", "⇧⌘A"), ("Settings", "⌘,")])
        ]

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let content = FlippedView(fill: Theme.window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        for (section, rows) in sections {
            let header = NSTextField.label(section.uppercased(), font: Fonts.semibold(10.5), color: Theme.tertiary)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(4, after: header)
            let grid = NSGridView(views: rows.map { row in
                [NSTextField.label(row.0, font: Fonts.regular(12.5), color: Theme.text),
                 NSTextField.label(row.1, font: Fonts.medium(12), color: Theme.secondary)]
            })
            grid.columnSpacing = 24
            grid.rowSpacing = 4
            grid.column(at: 0).width = 240
            grid.column(at: 1).xPlacement = .leading
            stack.addArrangedSubview(grid)
            stack.setCustomSpacing(18, after: grid)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        window.contentView = FillView(fill: Theme.window)
        window.contentView?.addSubviewPinned(scroll)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
    }
}


/// Forwards Item-menu actions to the list in the frontmost Things window.
final class ListActionRouter: NSObject, NSMenuItemValidation {
    static let shared = ListActionRouter()
    private var list: ListViewController { (MainWindowController.active ?? .shared).root.listVC }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || list.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { list }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { list.validateMenuItem(menuItem) }
}
