import Foundation
import AppKit

/// Headless checks for the parts that do not need a window: the store,
/// the list queries and the AI JSON contracts.
enum SelfTest {
    static func run() {
        var failures = 0
        let store = TaskStore.shared

        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("ok   \(label)")
            } else {
                failures += 1
                print("FAIL \(label)")
            }
        }

        let marker = "SelfTest " + UUID().uuidString.prefix(6)
        let task = store.createTask(title: marker, notes: "selftest note", bucket: .inbox)

        check(store.tasks(in: .builtin(.inbox)).contains { $0.id == task.id }, "new task lands in Inbox")
        check(store.task(task.id)?.notes == "selftest note", "notes persist in memory")
        do {
            let in20 = RemindPicker.parse("in 20 min")?.timeIntervalSinceNow ?? 0
            check(abs(in20 - 1200) < 5, "Remind Me parses “in 20 min”")
            let tomorrow9 = RemindPicker.parse("tomorrow 9am")
            check(tomorrow9.map { Calendar.current.component(.hour, from: $0) == 9 && $0.startOfDay == Date().startOfDay.addingDays(1) } == true, "Remind Me parses “tomorrow 9am”")
            check((RemindPicker.parse("3pm") ?? .distantPast) > Date(), "a bare time is always in the future")
            let at = ThingsAPI.dateTime("2026-11-20@14:30")
            check(at.map { Calendar.current.component(.hour, from: $0) == 14 && Calendar.current.component(.day, from: $0) == 20 } == true, "API reads Things 3 dates like 2026-11-20@14:30")
            check(Set(ThingsAPI.normalize(["append_checklist": ["x"], "checklistItems": ["y"]]).keys).isSuperset(of: ["append-checklist-items", "checklist-items"]), "API accepts snake_case and camelCase names")
            if case .reminder? = try? ThingsAPI.when("tomorrow 9am") { check(true, "API when with a time sets a reminder") } else { check(false, "API when with a time sets a reminder") }
        }
        do {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("things4.selftest.links"))
            pasteboard.clearContents()
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/Quarterly Report.pdf") as NSURL, URL(string: "https://www.example.com/docs/guide")! as NSURL])
            let links = Links.items(from: pasteboard)
            check(links.count == 2 && links[0].title == "Quarterly Report.pdf" && links[0].markdown.contains("Quarterly%20Report.pdf"), "dropped file becomes a Markdown link")
            check(links.count == 2 && links[1].title == "example.com › guide", "dropped web link gets a readable title")
            pasteboard.releaseGlobally()
        }

        store.setBucket(task.id, bucket: .scheduled, date: Date().startOfDay)
        check(store.tasks(in: .builtin(.today)).contains { $0.id == task.id }, "scheduled task lands in Today")

        store.setTags(task.id, ["selftest", "alpha"])
        check(store.task(task.id)?.tags == ["alpha", "selftest"], "tags are sorted and stored")
        check(store.tasks(in: .tag("selftest")).contains { $0.id == task.id }, "tag query finds the task")

        store.addChecklistItem(task.id, title: "step one")
        check(store.task(task.id)?.checklist.count == 1, "checklist item added")
        if let item = store.task(task.id)?.checklist.first {
            store.toggleChecklistItem(task.id, itemID: item.id)
            check(store.task(task.id)?.checklistDone == 1, "checklist item toggles")
        }

        store.setDeadline(task.id, date: Date().startOfDay)
        check(store.task(task.id)?.deadline != nil, "deadline stored")

        store.toggleCompletion(task.id)
        check(store.task(task.id)?.status == .completed, "task completes")
        check(store.tasks(in: .builtin(.logbook)).contains { $0.id == task.id }, "completed task lands in Logbook")

        store.toggleCompletion(task.id)
        check(store.task(task.id)?.status == .open, "task reopens")

        store.moveToTrash(task.id)
        check(store.tasks(in: .builtin(.trash)).contains { $0.id == task.id }, "task moves to Trash")
        store.restore(task.id)
        check(store.task(task.id)?.status == .open, "task restores")
        store.deletePermanently(task.id)
        check(store.task(task.id) == nil, "task deletes permanently")

        // Things 3 behaviours
        let evening = store.createTask(title: marker + " evening", bucket: .scheduled, startDate: Date().startOfDay, isEvening: true)
        check(store.tasks(in: .builtin(.today)).contains { $0.id == evening.id && $0.isEvening }, "evening task lands in Today")
        store.setBucket(evening.id, bucket: .anytime)
        check(store.task(evening.id)?.isEvening == false, "leaving Today clears evening")
        store.deletePermanently(evening.id)

        let repeating = store.createTask(title: marker + " repeat", bucket: .scheduled, startDate: Date().startOfDay)
        store.setRepeat(repeating.id, rule: RepeatRule(frequency: .daily, interval: 2))
        check(store.task(repeating.id)?.repeatRule?.summary == "Every 2 days", "repeat rule stored")
        let before = store.tasks.count
        store.toggleCompletion(repeating.id)
        let spawned = store.tasks.first { $0.title == marker + " repeat" && $0.isOpen }
        check(store.tasks.count == before + 1 && spawned != nil, "completing a repeating task spawns the next one")
        check(spawned?.startDate == Date().startOfDay.addingDays(2), "next occurrence is two days out")
        store.deletePermanently(repeating.id)
        if let spawned { store.deletePermanently(spawned.id) }

        let project = store.createProject(title: marker + " project")
        let heading = store.createHeading(title: "Phase 1", projectID: project.id)
        let child = store.createTask(title: "step", bucket: .anytime, projectID: project.id, headingID: heading.id)
        check(store.headings(of: project.id).count == 1, "heading belongs to project")
        check(store.task(child.id)?.headingID == heading.id, "to-do sits under heading")
        store.moveToTrash(heading.id)
        check(store.task(child.id)?.headingID == nil, "deleting a heading releases its to-dos")
        // Without a run loop the undo manager never closes its implicit group, so close it by hand.
        while store.undoManager.groupingLevel > 0 { store.undoManager.endUndoGrouping() }
        store.undoManager.beginUndoGrouping()
        store.cancel(child.id)
        store.undoManager.endUndoGrouping()
        check(store.task(child.id)?.isCanceled == true && store.tasks(in: .builtin(.logbook)).contains { $0.id == child.id }, "canceled task lands in Logbook")
        store.undoManager.undo()
        check(store.task(child.id)?.isOpen == true, "undo reopens the task")
        // Headless: keep an explicit group open for the rest of the run.
        store.undoManager.beginUndoGrouping()
        let copy = store.duplicate(child.id)
        check(copy != nil && copy?.title == "step" && copy?.index == (store.task(child.id)?.index ?? 0) + 1, "duplicate lands after the original")
        store.reorder([copy!.id, child.id])
        check(store.children(of: project.id).first?.id == copy!.id, "reorder changes indexes")
        check(store.search("step").contains { $0.id == child.id }, "quick find matches titles")
        // Sections directly in an area, without a project
        let area = store.createArea(title: marker + " area")
        let section = store.createHeading(title: "Errands", areaID: area.id)
        let inSection = store.createTask(title: "buy milk", bucket: .anytime, areaID: area.id, headingID: section.id)
        check(store.headings(inArea: area.id).map(\.id) == [section.id], "area can hold a section")
        check(store.tasks(in: .area(area.id)).contains { $0.id == inSection.id && $0.headingID == section.id }, "to-do sits in the area section")
        store.move(inSection.id, toProject: nil, areaID: nil)
        check(store.task(inSection.id)?.headingID == nil, "moving out of the area leaves the section")

        // Convert to project
        let convertible = store.createTask(title: "Plan trip", notes: "brief", bucket: .anytime, checklist: ["book flights", "hotel"])
        let converted = store.convertToProject(convertible.id)
        check(converted?.isProject == true && converted?.notes == "brief", "to-do converts into a project with its notes")
        check(store.children(of: converted?.id ?? "").filter(\.isTodo).map(\.title) == ["book flights", "hotel"], "checklist becomes the project's to-dos")
        check(store.task(convertible.id)?.status == .trashed, "original to-do goes to Trash")

        // Checklist reorder
        let listTask = store.createTask(title: marker + " list", bucket: .anytime, checklist: ["a", "b", "c"])
        store.moveChecklistItem(listTask.id, from: 0, to: 2)
        check(store.task(listTask.id)?.checklist.map(\.title) == ["b", "c", "a"], "checklist items reorder")
        store.deletePermanently(listTask.id)

        // Tag colours
        check(store.tagColor("Important") == .red, "Important defaults to red")
        store.setTagColor(marker + "tag", .purple)
        check(store.tagColor(marker + "tag") == .purple, "tag colour is stored")
        store.deleteTag(marker + "tag")

        // Export
        let exportProject = store.createProject(title: marker + " export")
        let exported = store.createTask(title: "Write slides", bucket: .anytime, projectID: exportProject.id, tags: ["Important"], checklist: ["Outline"])
        let md = Exporter.markdown(for: .project(exportProject.id)).text
        check(md.contains("# " + marker + " export") && md.contains("- [ ] Write slides") && md.contains("#Important") && md.contains("    - [ ] Outline"),
              "project exports to Markdown")
        store.deletePermanently(exported.id)
        store.deletePermanently(exportProject.id)

        // Markdown
        check(Markdown.plainPreview("# Title\n- [ ] ::key:: **point**") == "Title  ·  key point", "markdown preview strips markers")

        store.moveToTrash(project.id)
        check(store.task(child.id)?.status == .trashed, "trashing a project trashes its to-dos")
        store.emptyTrash()
        check(store.tasks(in: .builtin(.trash)).isEmpty, "empty trash removes everything")

        // AI JSON contracts
        let capture = """
        {"title":"Call the dentist","notes":"Ask about Friday","when":"tomorrow","deadline":null,"tags":["health"],"checklist":["Find the number"]}
        """
        if let object = AIJSON.object(from: capture), let draft = AIJSON.taskDraft(from: object) {
            check(draft.title == "Call the dentist" && draft.when == "tomorrow" && draft.tags == ["health"], "capture JSON parses")
            let created = AIJSON.apply(draft)
            check(created.bucket == .scheduled && created.startDate?.isTomorrow == true, "capture draft applies to Tomorrow")
            store.deletePermanently(created.id)
        } else {
            check(false, "capture JSON parses")
        }

        let plan = """
        {"title":"Launch page","notes":"Ship it","tasks":[{"title":"Write copy","when":"today"},{"title":"Build page","when":"tomorrow"}]}
        """
        let projectDraft = AIJSON.projectDraft(from: plan)
        check(projectDraft?.tasks.count == 2, "plan JSON parses")

        let triage = """
        {"items":[{"id":"abc","action":"defer","reason":"can wait"}]}
        """
        check(AIJSON.triage(from: triage).first?.action == "defer", "triage JSON parses")

        let search = """
        {"matches":[{"id":"abc","why":"same meaning"}]}
        """
        check(AIJSON.searchHits(from: search).first?.taskID == "abc", "search JSON parses")

        let polish = """
        {"title":"A clearer title","notes":"Detail"}
        """
        check(AIJSON.polish(from: polish)?.title == "A clearer title", "enhance JSON parses")

        print("")
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `--bench`: timing of the hot store paths on whatever database is loaded.
enum Bench {
    static func run() {
        let store = TaskStore.shared
        func time(_ label: String, _ body: () -> Void) {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            print(String(format: "%-34@ %7.2f ms", label, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        }
        print("tasks: \(store.tasks.count)")
        time("today query") { _ = store.tasks(in: .builtin(.today)) }
        time("upcoming query") { _ = store.tasks(in: .builtin(.upcoming)) }
        time("logbook query") { _ = store.tasks(in: .builtin(.logbook)) }
        time("sidebar counts (7 lists)") { for list in BuiltinList.allCases { _ = store.count(for: list) } }
        time("search 'review'") { _ = store.search("review") }
        time("task(id) x 5000") { for item in store.tasks.prefix(5000) { _ = store.task(item.id) } }
        let first = store.tasks(in: .builtin(.anytime)).prefix(200).map(\.id)
        time("reorder 200 (batched)") { store.reorder(first.reversed()) }
        time("create + trash + undo") {
            let t = store.createTask(title: "bench", bucket: .inbox)
            store.moveToTrash(t.id)
            store.deletePermanently(t.id)
        }
        time("markdown live style 4KB") {
            let storage = NSTextStorage(string: String(repeating: "# H\n- [ ] a **b** `c` [d](https://x.y)\n", count: 100))
            Markdown.applyLiveStyle(to: storage, baseSize: 13)
        }
        time("markdown render 4KB") {
            _ = Markdown.render(String(repeating: "# H\n- [ ] a **b** `c` [d](https://x.y)\n", count: 100), baseSize: 13)
        }
        exit(0)
    }
}
