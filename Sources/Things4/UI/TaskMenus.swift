import AppKit

enum DatePrompt {
    static func pick(title: String, initial: Date = Date()) -> Date? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Choose a date."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay]
        picker.dateValue = initial
        alert.accessoryView = picker
        let response = alert.runModal()
        Prompt.restoreFocus()
        return response == .alertFirstButtonReturn ? picker.dateValue : nil
    }
}

enum RepeatPrompt {
    /// Returns `nil` when canceled, `.some(nil)` to remove the repeat, or a rule.
    static func pick(initial: RepeatRule?) -> RepeatRule?? {
        let alert = NSAlert()
        alert.messageText = "Repeat"
        alert.informativeText = "Create the next to-do automatically when this one is completed."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        if initial != nil { alert.addButton(withTitle: "Remove Repeat") }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 92))
        let everyLabel = NSTextField(labelWithString: "Every")
        everyLabel.frame = NSRect(x: 0, y: 62, width: 40, height: 20)
        let interval = NSTextField(frame: NSRect(x: 44, y: 60, width: 44, height: 24))
        interval.integerValue = initial?.interval ?? 1
        interval.alignment = .center
        let stepper = NSStepper(frame: NSRect(x: 92, y: 58, width: 19, height: 27))
        stepper.minValue = 1
        stepper.maxValue = 365
        stepper.integerValue = initial?.interval ?? 1
        stepper.target = interval
        stepper.action = #selector(NSTextField.takeIntValueFrom(_:))
        let frequency = NSPopUpButton(frame: NSRect(x: 118, y: 59, width: 150, height: 26))
        for f in RepeatRule.Frequency.allCases { frequency.addItem(withTitle: f.unit.capitalized + "(s)") }
        if let initial, let index = RepeatRule.Frequency.allCases.firstIndex(of: initial.frequency) {
            frequency.selectItem(at: index)
        }
        let fromCompletion = NSButton(checkboxWithTitle: "Count from completion date", target: nil, action: nil)
        fromCompletion.frame = NSRect(x: 0, y: 26, width: 300, height: 20)
        fromCompletion.state = (initial?.afterCompletion ?? false) ? .on : .off
        let hint = NSTextField(wrappingLabelWithString: "Off: the next one is scheduled from the current start date.")
        hint.font = Fonts.regular(10.5)
        hint.textColor = Theme.secondary
        hint.frame = NSRect(x: 18, y: 0, width: 282, height: 24)
        for view in [everyLabel, interval, stepper, frequency, fromCompletion, hint] { container.addSubview(view) }
        alert.accessoryView = container

        let response = alert.runModal()
        Prompt.restoreFocus()
        if response == .alertThirdButtonReturn { return .some(nil) }
        guard response == .alertFirstButtonReturn else { return nil }
        let rule = RepeatRule(frequency: RepeatRule.Frequency.allCases[max(0, frequency.indexOfSelectedItem)],
                              interval: max(1, interval.integerValue),
                              afterCompletion: fromCompletion.state == .on)
        return .some(rule)
    }
}

/// Menus shared by the context menu, the inline editor and the bottom toolbar.
enum TaskMenus {
    private static func tasks(_ ids: [String]) -> [TaskItem] {
        ids.compactMap { TaskStore.shared.task($0) }
    }

    static func when(for ids: [String], done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let store = TaskStore.shared
        let items = tasks(ids)
        let single = items.count == 1 ? items.first : nil
        let tomorrow = Date().startOfDay.addingDays(1)

        menu.addItem(ClosureMenuItem("Today", symbol: "star.fill", key: "t", modifiers: .command,
                                     checked: single?.startDate?.isToday == true && single?.isEvening == false) {
            store.batch("Today") { ids.forEach { store.setBucket($0, bucket: .scheduled, date: Date().startOfDay) } }
            done()
        })
        menu.addItem(ClosureMenuItem("This Evening", symbol: "moon.fill", key: "e", modifiers: .command,
                                     checked: single?.isEvening == true) {
            ids.forEach { store.setEvening($0, true) }
            done()
        })
        menu.addItem(ClosureMenuItem("Tomorrow", symbol: "sunrise", checked: single?.startDate?.isTomorrow == true) {
            ids.forEach { store.setBucket($0, bucket: .scheduled, date: tomorrow) }
            done()
        })
        let weekend = nextWeekday(7)
        menu.addItem(ClosureMenuItem("This Weekend", symbol: "beach.umbrella") {
            ids.forEach { store.setBucket($0, bucket: .scheduled, date: weekend) }
            done()
        })
        let nextWeek = nextWeekday(2)
        menu.addItem(ClosureMenuItem("Next Week", symbol: "calendar") {
            ids.forEach { store.setBucket($0, bucket: .scheduled, date: nextWeek) }
            done()
        })
        menu.addItem(ClosureMenuItem("Pick a Date…", symbol: "calendar.badge.plus") {
            if let date = DatePrompt.pick(title: "When should this start?", initial: single?.startDate ?? Date()) {
                ids.forEach { store.setBucket($0, bucket: .scheduled, date: date) }
            }
            done()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Anytime", symbol: "square.stack.3d.up.fill", key: "r", modifiers: .command,
                                     checked: single?.bucket == .anytime) {
            ids.forEach { store.setBucket($0, bucket: .anytime) }
            done()
        })
        menu.addItem(ClosureMenuItem("Someday", symbol: "archivebox.fill", key: "o", modifiers: .command,
                                     checked: single?.bucket == .someday) {
            ids.forEach { store.setBucket($0, bucket: .someday) }
            done()
        })
        if items.contains(where: { $0.projectID == nil }) {
            menu.addItem(ClosureMenuItem("Inbox", symbol: "tray", checked: single?.bucket == .inbox) {
                ids.forEach { store.setBucket($0, bucket: .inbox) }
                done()
            })
        }
        return menu
    }

    static func deadline(for ids: [String], done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let store = TaskStore.shared
        let single = tasks(ids).count == 1 ? tasks(ids).first : nil
        if single?.deadline != nil || tasks(ids).contains(where: { $0.deadline != nil }) {
            menu.addItem(ClosureMenuItem("Remove Deadline", symbol: "flag.slash") {
                ids.forEach { store.setDeadline($0, date: nil) }
                done()
            })
            menu.addItem(.separator())
        }
        let options: [(String, Int)] = [("Today", 0), ("Tomorrow", 1), ("In 3 Days", 3), ("In a Week", 7), ("In Two Weeks", 14), ("In a Month", 30)]
        for (title, days) in options {
            menu.addItem(ClosureMenuItem(title, symbol: "flag") {
                ids.forEach { store.setDeadline($0, date: Date().startOfDay.addingDays(days)) }
                done()
            })
        }
        menu.addItem(ClosureMenuItem("Pick a Date…", symbol: "calendar.badge.plus") {
            if let date = DatePrompt.pick(title: "Deadline", initial: single?.deadline ?? Date()) {
                ids.forEach { store.setDeadline($0, date: date) }
            }
            done()
        })
        return menu
    }

    static func move(for ids: [String], done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let store = TaskStore.shared
        let single = tasks(ids).count == 1 ? tasks(ids).first : nil
        let onlyTodos = tasks(ids).allSatisfy(\.isTodo)

        menu.addItem(ClosureMenuItem("Inbox", symbol: "tray", checked: single?.projectID == nil && single?.areaID == nil && single?.bucket == .inbox) {
            ids.forEach { store.move($0, toProject: nil, areaID: nil); store.setBucket($0, bucket: .inbox) }
            done()
        })
        menu.addItem(ClosureMenuItem("No Project or Area", symbol: "minus.circle", checked: single?.projectID == nil && single?.areaID == nil && single?.bucket != .inbox) {
            ids.forEach { store.move($0, toProject: nil, areaID: nil) }
            done()
        })
        menu.addItem(.separator())
        for area in store.areas.sorted(by: { $0.index < $1.index }) {
            let sections = store.headings(inArea: area.id).filter(\.isOpen)
            if sections.isEmpty || !onlyTodos {
                menu.addItem(ClosureMenuItem(area.title, symbol: "shippingbox", checked: single?.areaID == area.id && single?.projectID == nil) {
                    ids.forEach { store.move($0, toProject: nil, areaID: area.id) }
                    done()
                })
            } else {
                let item = NSMenuItem(title: area.title, action: nil, keyEquivalent: "")
                item.image = NSImage.symbol("shippingbox", size: 12, weight: .regular, color: Theme.secondary)
                let submenu = NSMenu()
                submenu.addItem(ClosureMenuItem(area.title, checked: single?.areaID == area.id && single?.projectID == nil && single?.headingID == nil) {
                    ids.forEach { store.move($0, toProject: nil, areaID: area.id, headingID: nil) }
                    done()
                })
                submenu.addItem(.separator())
                for section in sections {
                    submenu.addItem(ClosureMenuItem(section.title, checked: single?.headingID == section.id) {
                        ids.forEach { store.move($0, toProject: nil, areaID: area.id, headingID: section.id) }
                        done()
                    })
                }
                item.submenu = submenu
                menu.addItem(item)
            }
            if onlyTodos {
                for project in store.projects(inArea: area.id) where project.isOpen {
                    menu.addItem(projectItem(project, ids: ids, single: single, indent: true, done: done))
                }
            }
        }
        if onlyTodos {
            let loose = store.projects(inArea: nil).filter(\.isOpen)
            if !loose.isEmpty && !store.areas.isEmpty { menu.addItem(.separator()) }
            for project in loose {
                menu.addItem(projectItem(project, ids: ids, single: single, indent: false, done: done))
            }
        }
        return menu
    }

    private static func projectItem(_ project: TaskItem, ids: [String], single: TaskItem?, indent: Bool,
                                    done: @escaping () -> Void) -> NSMenuItem {
        let store = TaskStore.shared
        let headings = store.headings(of: project.id)
        let title = (indent ? "   " : "") + project.title
        if headings.isEmpty {
            return ClosureMenuItem(title, symbol: "circle", checked: single?.projectID == project.id) {
                ids.forEach { store.move($0, toProject: project.id, areaID: project.areaID) }
                done()
            }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage.symbol("circle", size: 12, weight: .regular, color: Theme.secondary)
        let submenu = NSMenu()
        submenu.addItem(ClosureMenuItem(project.title, checked: single?.projectID == project.id && single?.headingID == nil) {
            ids.forEach { store.move($0, toProject: project.id, areaID: project.areaID, headingID: nil) }
            done()
        })
        submenu.addItem(.separator())
        for heading in headings {
            submenu.addItem(ClosureMenuItem(heading.title, checked: single?.headingID == heading.id) {
                ids.forEach { store.move($0, toProject: project.id, areaID: project.areaID, headingID: heading.id) }
                done()
            })
        }
        item.submenu = submenu
        return item
    }

    static func tags(for ids: [String], done: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu()
        let store = TaskStore.shared
        let items = tasks(ids)
        for tag in store.allTags {
            let all = items.allSatisfy { $0.tags.contains(tag) }
            menu.addItem(ClosureMenuItem(tag, symbol: "tag", checked: all) {
                for item in items {
                    var tags = Set(item.tags)
                    if all { tags.remove(tag) } else { tags.insert(tag) }
                    store.setTags(item.id, Array(tags))
                }
                done()
            })
        }
        if !store.allTags.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("New Tag…", symbol: "plus") {
            if let value = Prompt.text(title: "Add Tag", message: "Tags are separated by commas.", placeholder: "Tag", button: "Add") {
                let new = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                for item in items { store.setTags(item.id, item.tags + new) }
            }
            done()
        })
        return menu
    }

    static func showRepeat(for ids: [String], done: @escaping () -> Void = {}) {
        let single = tasks(ids).count == 1 ? tasks(ids).first : nil
        guard let choice = RepeatPrompt.pick(initial: single?.repeatRule) else { return }
        ids.forEach { TaskStore.shared.setRepeat($0, rule: choice) }
        done()
    }

    /// The full right-click menu for one or more items.
    static func context(for ids: [String], selection: Selection, done: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        let store = TaskStore.shared
        let items = tasks(ids)
        guard !items.isEmpty else { return menu }
        let plural = items.count > 1
        let allHeadings = items.allSatisfy(\.isHeading)
        let inTrash = items.allSatisfy { $0.status == .trashed }

        if inTrash {
            menu.addItem(ClosureMenuItem("Put Back", symbol: "arrow.uturn.backward") {
                ids.forEach { store.restore($0) }
                done()
            })
            menu.addItem(ClosureMenuItem("Delete Permanently", symbol: "trash") {
                if Prompt.confirm(title: plural ? "Delete \(items.count) items?" : "Delete “\(items[0].title)”?",
                                  message: "This cannot be undone.", button: "Delete") {
                    ids.forEach { store.deletePermanently($0) }
                }
                done()
            })
            return menu
        }

        if allHeadings {
            let heading = items[0]
            menu.addItem(ClosureMenuItem("Convert to Project…", symbol: "circle.dashed") {
                guard Prompt.confirm(title: "Convert “\(heading.title)” into a project?", message: "Its to-dos move into the new project.", button: "Convert") else { return }
                if let project = store.convertToProject(heading.id) { AppState.shared.selection = .project(project.id) }
            })
            menu.addItem(ClosureMenuItem("Rename Heading…", symbol: "pencil") {
                if let title = Prompt.text(title: "Rename Heading", message: "", placeholder: "Heading", initial: heading.title, button: "Rename") {
                    store.setTitle(heading.id, title)
                }
                done()
            })
            menu.addItem(ClosureMenuItem("New To-Do Under Heading", symbol: "plus") {
                if let projectID = heading.projectID {
                    store.createTask(title: "New To-Do", bucket: .anytime, projectID: projectID,
                                     areaID: store.task(projectID)?.areaID, headingID: heading.id)
                }
                done()
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Heading", symbol: "trash") {
                ids.forEach { store.moveToTrash($0) }
                done()
            })
            return menu
        }

        let list = (MainWindowController.active ?? .shared).root.listVC
        let todos = items.allSatisfy(\.isTodo)
        let noun = items.allSatisfy(\.isProject) ? "Project" : "To-Do"
        menu.addItem(ClosureMenuItem("When…") { list.showWhen(nil) })
        menu.addItem(ClosureMenuItem("Move…") { list.showMove(nil) })
        if todos { menu.addItem(ClosureMenuItem("Tags…") { list.showTags(nil) }) }
        menu.addItem(ClosureMenuItem("Deadline…") { list.showDeadline(nil) })
        if todos { menu.addItem(ClosureMenuItem("Remind Me…") { list.showRemind(nil) }) }

        let completeItem = NSMenuItem(title: "Complete", action: nil, keyEquivalent: "")
        let completeMenu = NSMenu()
        if items.contains(where: \.isOpen) {
            completeMenu.addItem(ClosureMenuItem("Mark as Completed", key: "k", modifiers: .command) {
                store.batch("Complete") { ids.forEach { if store.task($0)?.isOpen == true { store.toggleCompletion($0) } } }
                done()
            })
            completeMenu.addItem(ClosureMenuItem("Mark as Canceled", key: "k", modifiers: [.command, .option]) {
                store.batch("Cancel") { ids.forEach { store.cancel($0) } }
                done()
            })
        } else {
            completeMenu.addItem(ClosureMenuItem("Mark as Open") {
                store.batch("Reopen") { ids.forEach { store.reopen($0) } }
                done()
            })
        }
        completeItem.submenu = completeMenu
        menu.addItem(completeItem)
        menu.addItem(.separator())

        if todos {
            menu.addItem(ClosureMenuItem("Repeat…") { showRepeat(for: ids, done: done) })
        }
        menu.addItem(ClosureMenuItem(plural ? "Duplicate" : "Duplicate \(noun)") {
            store.batch("Duplicate") { ids.forEach { store.duplicate($0) } }
            done()
        })
        if items.count == 1, items[0].isTodo, items[0].isOpen {
            let focusItem = NSMenuItem(title: "Start Focus Timer", action: nil, keyEquivalent: "")
            let focusMenu = NSMenu()
            for minutes in [15, 25, 45, 60] {
                focusMenu.addItem(ClosureMenuItem("\(minutes) minutes") { FocusTimer.shared.start(taskID: items[0].id, minutes: minutes) })
            }
            focusItem.submenu = focusMenu
            menu.addItem(focusItem)
        }
        if items.count == 1, items[0].isTodo {
            menu.addItem(ClosureMenuItem("Convert to Project…") {
                let item = items[0]
                let detail = item.checklist.isEmpty ? "" : " Its \(item.checklist.count) checklist item\(item.checklist.count == 1 ? "" : "s") become to-dos."
                guard Prompt.confirm(title: "Convert “\(item.title)” into a project?", message: "The notes come along." + detail, button: "Convert") else { return }
                if let project = store.convertToProject(item.id) { AppState.shared.selection = .project(project.id) }
            })
            menu.addItem(ClosureMenuItem("Open as Page") {
                NotificationCenter.default.post(name: .openNotePage, object: items[0].id)
            })
        }
        menu.addItem(ClosureMenuItem(plural ? "Delete" : "Delete \(noun)") {
            store.batch("Delete") { ids.forEach { store.moveToTrash($0) } }
            done()
        })
        if todos, items.contains(where: { $0.projectID != nil || $0.areaID != nil }) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove From Project") {
                store.batch("Move") { ids.forEach { store.move($0, toProject: nil, areaID: nil) } }
                done()
            })
        }
        if items.count == 1 {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Get Info") { showInfo(items[0]) })
            menu.addItem(ClosureMenuItem("Share…", symbol: "square.and.arrow.up") { share(items) })
        }
        if items.count == 1, items[0].projectID != nil || items[0].areaID != nil {
            if case .builtin = selection {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(items[0].projectID != nil ? "Show in Project" : "Show in Area") {
                    NotificationCenter.default.post(name: .openTask, object: items[0].id)
                })
            }
        }
        return menu
    }

    static func showInfo(_ task: TaskItem) {
        let store = TaskStore.shared
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        var lines = ["Created: " + f.string(from: task.createdAt), "Modified: " + f.string(from: task.modifiedAt)]
        if let done = task.completedAt { lines.append((task.isCanceled ? "Canceled: " : "Completed: ") + f.string(from: done)) }
        if let start = task.startDate { lines.append("Starts: " + Format.relativeDay(start)) }
        if let reminder = task.reminder { lines.append("Reminder: " + f.string(from: reminder)) }
        if let deadline = task.deadline { lines.append("Deadline: " + Format.relativeDay(deadline)) }
        if let rule = task.repeatRule { lines.append("Repeats: " + rule.summary) }
        let parent = task.projectID.flatMap { store.task($0)?.title } ?? task.areaID.flatMap { store.area($0)?.title }
        if let parent { lines.append("List: " + parent) }
        if task.isProject {
            let p = store.projectProgress(task.id)
            lines.append("Progress: \(p.done) of \(p.total) to-dos")
        }
        let words = task.notes.split { $0.isWhitespace || $0.isNewline }.count
        if words > 0 { lines.append("Notes: \(words) words") }
        let alert = NSAlert()
        alert.messageText = task.title
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
        Prompt.restoreFocus()
    }

    /// Shares the to-dos as plain text (title, notes, checklist).
    static func share(_ items: [TaskItem]) {
        let text = items.map { task -> String in
            var parts = [task.title]
            if !task.notes.isEmpty { parts.append(task.notes) }
            if !task.checklist.isEmpty { parts.append(task.checklist.map { ($0.done ? "- [x] " : "- [ ] ") + $0.title }.joined(separator: "\n")) }
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
        guard let view = (MainWindowController.active ?? .shared).window?.contentView else { return }
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// Next occurrence of a weekday (1 = Sunday … 7 = Saturday), at least tomorrow.
    private static func nextWeekday(_ weekday: Int) -> Date {
        var date = Date().startOfDay.addingDays(1)
        while Calendar.current.component(.weekday, from: date) != weekday { date = date.addingDays(1) }
        return date
    }
}
