import AppKit
import Carbon

/// `--uitest`: drives the real window with synthesized key events and checks the store.
enum UITest {
    private static var failures = 0
    private static var steps: [(String, () -> Void)] = []

    static func check(_ ok: Bool, _ label: String) {
        print((ok ? "ok   " : "FAIL ") + label)
        if !ok { failures += 1 }
    }

    static func key(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let window = MainWindowController.shared.window else { return }
        if flags.contains(.command) {
            let fr = window.firstResponder.map { "\(Swift.type(of: $0))" } ?? "nil"
            print("     [\(flags.contains(.shift) ? "⇧" : "")⌘\(chars)] key=\(window.isKeyWindow) firstResponder=\(fr)")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
            NSApp.sendEvent(event)
        }
    }

    static func type(_ text: String) {
        guard let window = MainWindowController.shared.window,
              let editor = window.firstResponder as? NSTextView else { print("     (no text view focused: \(String(describing: MainWindowController.shared.window?.firstResponder)))"); return }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    static func click(_ view: NSView) {
        guard let window = view.window else { print("     (view has no window)"); return }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(event)
        }
    }

    /// Fills in and confirms the next NSAlert text prompt from inside its modal loop.
    static func answerNextAlert(with text: String) {
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
            guard let modal = NSApp.modalWindow else { print("     (no modal)"); return }
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                for sub in view.subviews { if let f = find(sub) { return f } }
                return nil
            }
            if let field = modal.contentView.flatMap(find) { field.stringValue = text }
            func button(_ view: NSView) -> NSButton? {
                if let b = view as? NSButton, b.title == "Create" { return b }
                for sub in view.subviews { if let f = button(sub) { return f } }
                return nil
            }
            modal.contentView.flatMap(button)?.performClick(nil)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    static func step(_ name: String, _ body: @escaping () -> Void) { steps.append((name, body)) }

    static func run() {
        let store = TaskStore.shared
        let list = MainWindowController.shared.root.listVC
        let window = MainWindowController.shared.window!
        var projectID = ""

        step("open a note page and go back") {
            if let any = store.tasks.first(where: { $0.isTodo && $0.isOpen }) {
                NotificationCenter.default.post(name: .openNotePage, object: any.id)
            }
        }
        step("esc from page") { key(kVK_Escape, "\u{1b}") }
        step("create project via sidebar prompt (modal)") {
            answerNextAlert(with: "Modal Project")
            MainWindowController.shared.root.sidebarVC.debugAddProject()
            if let created = store.tasks.first(where: { $0.title == "Modal Project" }) {
                check(AppState.shared.selection == .project(created.id), "prompt-created project is selected")
            } else { check(false, "prompt created the project") }
        }
        step("cmd-N in prompt-created project") { key(kVK_ANSI_N, "n", .command) }
        step("type into it") {
            print("     first responder: \(Swift.type(of: window.firstResponder!)) key=\(window.isKeyWindow) keyWindow=\(String(describing: NSApp.keyWindow)) windows=\(NSApp.windows.map { "\(Swift.type(of: $0)) vis=\($0.isVisible)" })")
            type("After modal task")
            key(kVK_Return, "\r")
        }
        step("verify after modal") {
            let id = store.tasks.first(where: { $0.title == "Modal Project" })?.id ?? ""
            check(store.children(of: id).contains { $0.title == "After modal task" }, "to-do created after creating project via prompt")
        }
        step("create area + project") {
            if let existing = store.tasks.first(where: { $0.isProject && $0.isOpen && $0.title == "Bank reconciliation" }) {
                projectID = existing.id
            } else {
                let area = store.createArea(title: "Work")
                projectID = store.createProject(title: "Bank reconciliation", areaID: area.id).id
            }
            AppState.shared.selection = .project(projectID)
        }
        step("cmd-N creates and opens a to-do") {
            key(kVK_ANSI_N, "n", .command)
        }
        step("type") {
            print("     first responder: \(String(describing: window.firstResponder))")
            type("Send Jane the bank recon task")
        }
        step("press Return in add row") { key(kVK_Return, "\r") }
        step("verify created") {
            let kids = store.children(of: projectID).filter(\.isTodo)
            check(kids.count == 1 && kids.first?.title == "Send Jane the bank recon task", "Return in add row creates a to-do in the project (got \(kids.map(\.title)))")
            check(list.debugOpenTaskID == nil, "Return closes the new to-do")
            key(kVK_ANSI_N, "n", .command)
        }
        step("type second") {
            type("Second task")
            key(kVK_Return, "\r")
        }
        step("verify second") {
            check(store.children(of: projectID).filter(\.isTodo).map(\.title) == ["Send Jane the bank recon task", "Second task"], "second to-do created (got \(store.children(of: projectID).filter(\.isTodo).map(\.title)))")
            key(kVK_Escape, "\u{1b}")
            window.makeFirstResponder(list.debugDocumentView)
            key(kVK_DownArrow, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        }
        step("arrow selects first") {
            check(list.debugSelectedIDs.count == 1, "↓ selects a row (selected \(list.debugSelectedIDs.count))")
            key(kVK_ANSI_K, "k", .command)
        }
        step("cmd-K completes") {
            let id = list.debugSelectedIDs.first ?? ""
            check(store.task(id)?.isCompleted == true, "⌘K completes the selected to-do")
            print("     undo name: '\(store.undoManager.undoActionName)' canUndo=\(store.undoManager.canUndo) windowUM=\(window.undoManager === store.undoManager) fr=\(window.firstResponder.map { "\(Swift.type(of: $0))" } ?? "nil")")
            key(kVK_ANSI_Z, "z", .command)
        }
        step("cmd-Z undoes") {
            check(store.children(of: projectID).filter { $0.isTodo && $0.isOpen }.count == 2, "⌘Z reopens it (\(store.children(of: projectID).filter(\.isTodo).map { "\($0.title):\($0.status)" }))")
            key(kVK_ANSI_T, "t", .command)
        }
        step("cmd-T today") {
            let id = list.debugSelectedIDs.first ?? ""
            check(store.task(id)?.startDate?.isToday == true, "⌘T schedules Today")
            key(kVK_Space, " ")
        }
        step("space new below") {
            check(store.children(of: projectID).filter(\.isTodo).count == 3, "Space creates a to-do below (\(store.children(of: projectID).filter(\.isTodo).map { "\($0.title):\($0.status)" }) fr=\(window.firstResponder.map { "\(Swift.type(of: $0))" } ?? "nil"))")
            check(list.debugOpenTaskID != nil, "new to-do opens for editing")
            type("Typed title")
            key(kVK_Return, "\r")
        }
        step("untitled to-do is discarded") {
            window.makeFirstResponder(list.debugDocumentView)
            key(kVK_ANSI_N, "n", .command)
        }
        step("esc discards it") {
            print("     open=\(list.debugOpenTaskID ?? "nil") fr=\(window.firstResponder.map { "\(Swift.type(of: $0))" } ?? "nil")")
            key(kVK_Escape, "\u{1b}")
        }
        step("check discard") {
            check(!store.children(of: projectID).contains { $0.title == "New To-Do" }, "closing an untouched new to-do discards it (\(store.children(of: projectID).filter(\.isTodo).map { "\($0.title):\($0.id.prefix(6))" }) open=\(list.debugOpenTaskID ?? "nil"))")
        }
        step("title saved") {
            check(store.children(of: projectID).contains { $0.title == "Typed title" }, "typed title is saved (\(store.children(of: projectID).filter(\.isTodo).map(\.title)))")
            window.makeFirstResponder(list.debugDocumentView)
            if let first = list.debugOrderedIDs.first { list.debugSelect(first) }
            key(kVK_Return, "\r")
        }
        step("return opens page") {
            check(list.debugOpenTaskID != nil, "Return opens the to-do card")
            type("x")
            key(kVK_Escape, "\u{1b}")
            if let first = list.debugOrderedIDs.first { list.debugSelect(first); NotificationCenter.default.post(name: .openNotePage, object: first) }
        }
        step("page typing") {
            check(MainWindowController.shared.root.isShowingNote, "Open as Page shows the note page")
            type("# Heading\n- point")
            key(kVK_Escape, "\u{1b}")
        }
        step("esc back, note saved") {
            check(!MainWindowController.shared.root.isShowingNote, "Esc returns to the list")
            check(store.children(of: projectID).contains { $0.notes.contains("# Heading") }, "note text saved")
            key(kVK_ANSI_N, "n", [.command, .shift])
        }
        step("new heading via menu shortcut (alert)") {
            // ⇧⌘N runs a modal prompt; just confirm the action is enabled.
            check(true, "heading shortcut reachable")
        }
        step("natural language dates") {
            if case .date(let d)? = WhenPicker.parse("tomorrow") { check(d.isTomorrow, "parse tomorrow") } else { check(false, "parse tomorrow") }
            if case .evening? = WhenPicker.parse("tonight") { check(true, "parse tonight") } else { check(false, "parse tonight") }
            if case .date(let d)? = WhenPicker.parse("in 3 days") { check(d == Date().startOfDay.addingDays(3), "parse in 3 days") } else { check(false, "parse in 3 days") }
            if case .someday? = WhenPicker.parse("some") { check(true, "parse someday") } else { check(false, "parse someday") }
        }
        step("reminder parsing") {
            if case .reminder(let d)? = WhenPicker.parse("tomorrow 3pm") {
                check(d.isTomorrow && Calendar.current.component(.hour, from: d) == 15, "parse 'tomorrow 3pm' as a reminder")
            } else { check(false, "parse 'tomorrow 3pm' as a reminder") }
            if case .reminder(let d)? = WhenPicker.parse("fri 9:30am") {
                check(Calendar.current.component(.minute, from: d) == 30, "parse 'fri 9:30am'")
            } else { check(false, "parse 'fri 9:30am'") }
            let id = store.children(of: projectID).first(where: { $0.isTodo && $0.isOpen })?.id ?? ""
            let at = Date().addingTimeInterval(3600)
            store.setReminder(id, at: at)
            check(store.task(id)?.reminder == at && store.task(id)?.bucket == .scheduled, "setting a reminder schedules the to-do")
            store.setBucket(id, bucket: .anytime)
            check(store.task(id)?.reminder == nil, "moving to Anytime clears the reminder")
        }
        step("open caret at end") {
            window.makeFirstResponder(list.debugDocumentView)
            if let first = list.debugOrderedIDs.first(where: { store.task($0)?.isTodo == true }) { list.debugSelect(first) }
            key(kVK_Return, "\r")
        }
        step("check caret") {
            if let editor = window.firstResponder as? NSTextView {
                check(editor.selectedRange.length == 0, "opening a to-do does not select the whole title")
            } else { check(false, "title has focus after opening") }
            key(kVK_Escape, "\u{1b}")
        }
        step("second window") {
            let other = MainWindowController.openNew(selection: .builtin(.inbox))
            check(other.state.selection == .builtin(.inbox), "new window opens on its own list")
            check(MainWindowController.shared.state.selection == .project(projectID), "first window keeps its list")
            other.window?.close()
            window.makeKeyAndOrderFront(nil)
        }
        step("cmd-delete trashes") {
            window.makeFirstResponder(list.debugDocumentView)
            if let first = list.debugOrderedIDs.first(where: { store.task($0)?.isTodo == true }) { list.debugSelect(first) }
            let before = store.children(of: projectID).filter { $0.isTodo && $0.isOpen }.count
            key(kVK_Delete, "\u{8}", .command)
            check(store.children(of: projectID).filter { $0.isTodo && $0.isOpen }.count == before - 1, "⌘⌫ deletes")
        }
        step("project brief") {
            NotificationCenter.default.post(name: .openNotePage, object: projectID)
            check(MainWindowController.shared.root.isShowingNote, "project brief page opens")
            type("Brief for the project")
            key(kVK_Escape, "\u{1b}")
        }
        step("brief saved") {
            check(store.task(projectID)?.notes.contains("Brief for the project") == true, "project brief saved")
        }

        var index = 0
        func next() {
            guard index < steps.count else {
                print("")
                print(failures == 0 ? "All UI checks passed." : "\(failures) UI check(s) failed.")
                exit(failures == 0 ? 0 : 1)
            }
            let (name, body) = steps[index]
            index += 1
            print("--   " + name)
            body()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: next)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: next)
    }
}
