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
            let project = store.createProject(title: marker + " flow project")
            let first = store.createTask(title: marker + " flow first", bucket: .anytime, projectID: project.id)
            let second = store.createTask(title: marker + " flow second", bucket: .someday, projectID: project.id)
            check(store.task(first.id)?.flow == .todo && store.task(first.id)?.priority == Priority.none, "a new to-do starts as Todo with no priority")
            store.setFlow(first.id, .progress)
            check(store.task(first.id)?.stage == .progress && store.task(first.id)?.isDueToday == true, "In Progress plans the to-do for today")
            check(store.tasks(in: .builtin(.active)).contains { $0.id == first.id }, "In Progress to-dos show in Active")
            store.setWaiting(second.id, blockedBy: first.id)
            check(store.task(second.id)?.stage == .waiting && store.waitingLabel(store.task(second.id)!) == "Blocked by " + first.title,
                  "a to-do can be blocked by another")
            check(store.tasks(in: .builtin(.active)).map(\.id).firstIndex(of: first.id)! < store.tasks(in: .builtin(.active)).map(\.id).firstIndex(of: second.id)!,
                  "Active lists In Progress before Waiting")
            store.setFlow(first.id, .done)
            check(store.task(first.id)?.isCompleted == true && store.task(second.id)?.stage == .todo && store.task(second.id)?.blockedBy == nil,
                  "finishing the blocker moves the blocked to-do back to Todo")
            store.undoManager.undo()
            check(store.task(first.id)?.flow == .progress && store.task(second.id)?.blockedBy == first.id, "undo restores the status and the block together")
            store.setWaiting(second.id, on: "Henry")
            check(store.waitingLabel(store.task(second.id)!) == "Waiting on Henry", "a to-do can wait on a person")
            store.setFlow(second.id, .backlog)
            check(store.task(second.id)?.waitingOn == nil, "leaving Waiting clears what it waited on")
            store.setFlow(second.id, .canceled)
            check(store.task(second.id)?.flow == .canceled, "Canceled goes through the cancel path")
            store.setFlow(second.id, .todo)
            check(store.task(second.id)?.isOpen == true && store.task(second.id)?.flow == .todo, "a closed to-do can be set straight back to Todo")
            store.setPriority(first.id, .urgent)
            store.setEstimate(first.id, minutes: 90)
            check(store.task(first.id)?.priority == .urgent && store.estimateTotal([store.task(first.id)!]) == 90, "priority and estimate are stored")
            check(WorkflowMenus.parseMinutes("1.5h") == 90 && WorkflowMenus.parseMinutes("1h 30m") == 90 && WorkflowMenus.parseMinutes("45") == 45
                  && WorkflowMenus.parseMinutes("soon") == nil, "estimates read 1.5h, 1h 30m and plain minutes")
            check(Flow.named("In Progress") == .progress && Flow.named("blocked") == .waiting && Flow.named("nope") == nil, "status names are read loosely")
            let updated = try? ThingsAPI.update(["id": second.id, "state": "waiting", "waiting_on": "the bank", "priority": "high", "estimate": "2h"])
            let encoded = updated.map(ThingsAPI.encode)
            check(encoded?["state"] as? String == "waiting" && encoded?["waiting-on"] as? String == "the bank"
                  && encoded?["priority"] as? String == "high" && encoded?["estimate_minutes"] as? Int == 120, "API sets and returns state, priority, estimate and waiting-on")
            check((try? ThingsAPI.update(["id": second.id, "state": "sideways"])) == nil, "API refuses an unknown state")
            check(((try? ThingsAPI.query(["state": "in-progress"])) ?? []).contains { $0.id == first.id }, "API filters to-dos by state")
            let added = try? ThingsAPI.add(["title": marker + " flow added", "state": "in-progress", "priority": "low", "list": project.title])
            check(added?.first?.stage == .progress && added?.first?.priority == .low, "API creates a to-do in a given state")
            check(store.areaTodos("no-such-area").isEmpty, "an unknown area has no to-dos")
        }
        do {
            let staging = store.createTask(title: marker + " package the staging build", bucket: .anytime)
            let invoice = store.createTask(title: marker + " send the Zenith invoice", bucket: .someday)
            let ramble = "Okay so today I really need to get the \(marker) staging build packaged, that's the most important thing. " +
                "Then I should send the \(marker) Zenith invoice. If I have time I'd like to sketch the onboarding flow for about 45 minutes, and tonight I want to call my mum."
            let plan = DayPlanner.offline(ramble)
            check(plan.count == 4, "a ramble becomes one item per thing said (got \(plan.map(\.title)))")
            check(plan.first?.taskID == staging.id && plan.first?.priority == .urgent, "the thing called most important comes first and matches the existing to-do")
            check(plan.contains { $0.taskID == invoice.id && $0.priority == .medium }, "a second existing to-do is recognised")
            let sketch = plan.first { $0.title.lowercased().contains("sketch") }
            check(sketch?.taskID == nil && sketch?.priority == .low && sketch?.estimate == 45 && sketch?.title == "Sketch the onboarding flow",
                  "an if-I-have-time item is new, low priority, with its estimate (got \(sketch?.title ?? "nil"))")
            check(plan.contains { $0.title == "Call my mum" && $0.when == .evening }, "tonight becomes This Evening")
            let listed = DayPlanner.offline("I need to get the tax return, the car insurance, and the dentist booking done today. These are my priorities for today.")
            check(listed.map(\.title) == ["The tax return", "The car insurance", "The dentist booking"] && listed.allSatisfy { $0.priority == .high },
                  "a spoken list splits into to-dos, all marked as priorities (got \(listed.map(\.title)))")
            let ids = DayPlanner.apply(plan)
            let today = store.tasks(in: .builtin(.today)).map(\.id)
            check(ids.count == 4 && today.first == staging.id && store.task(staging.id)?.priority == .urgent && store.task(invoice.id)?.isDueToday == true,
                  "applying the plan fills Today in priority order")
            check(store.tasks(in: .builtin(.today)).contains { $0.title == "Call my mum" && $0.isEvening }, "the evening item lands in This Evening")
            store.undoManager.undo()
            check(store.task(invoice.id)?.bucket == .someday && !store.tasks.contains { $0.title == "Call my mum" && $0.status != .trashed }, "one undo takes the whole plan back")
            let parsed = DayPlanner.parse(["items": [["id": staging.id, "title": "ignored", "priority": "urgent", "when": "today"],
                                                    ["id": NSNull(), "title": "Book flights", "priority": "low", "when": "tomorrow", "estimate_minutes": 20],
                                                    ["id": "not-a-real-id", "title": "Renew passport", "priority": "high"]]])
            check(parsed.count == 3 && parsed[0].title == staging.title && parsed[1].when == .tomorrow && parsed[1].estimate == 20 && parsed[2].taskID == nil,
                  "a model's answer is read, keeping real ids and treating unknown ones as new")
            check(AIClient.isLocal("http://localhost:11434/v1") && !AIClient.isLocal("https://api.openai.com/v1"), "a model server on this Mac needs no key")
            let grey = NSColor(srgbRed: 0.157, green: 0.157, blue: 0.163, alpha: 1), blue = NSColor(srgbRed: 0.40, green: 0.68, blue: 0.95, alpha: 1)
            check(DarkTheme.midnight.adapt(grey).usingColorSpace(.sRGB)!.redComponent < 0.06 && DarkTheme.slate.adapt(grey).usingColorSpace(.sRGB)!.blueComponent > DarkTheme.slate.adapt(grey).usingColorSpace(.sRGB)!.redComponent
                  && DarkTheme.midnight.adapt(blue) == blue && DarkTheme.graphite.adapt(grey) == grey, "dark themes re-tint surfaces and leave accents alone")
        }
        do {
            let notes = "Turn my reading notes into a weekly newsletter.\n\n## Plan\n- [ ] Pick a name\n- [ ] Draft the first issue\n- [x] Look at Buttondown\n\nMore thoughts."
            let idea = store.createIdea(title: marker + " newsletter", notes: notes)
            let everywhere: [Selection] = [.builtin(.inbox), .builtin(.today), .builtin(.anytime), .builtin(.someday), .builtin(.upcoming), .builtin(.active), .builtin(.logbook)]
            check(store.tasks(in: .builtin(.ideas)).first?.id == idea.id && !everywhere.contains { store.tasks(in: $0).contains { $0.id == idea.id } }
                  && !store.openProjects.contains { $0.id == idea.id }, "an idea lives only in Ideas")
            check(idea.pitch == "Turn my reading notes into a weekly newsletter." && store.homeSelection(for: idea) == .builtin(.ideas), "an idea's pitch is its first line")
            store.setIdeaStage(idea.id, .researching)
            check(store.task(idea.id)?.ideaStage == .researching, "an idea's stage changes")
            let split = TaskStore.extractSteps(from: notes)
            check(split.steps == ["Pick a name", "Draft the first issue"] && split.notes.contains("- [x] Look at Buttondown") && !split.notes.contains("Pick a name")
                  && !split.notes.contains("\n\n\n"), "open checkboxes come out of the notes as steps")
            check(store.ideaPrompt(idea.id).contains("Draft the first issue") && store.ideaPrompt(idea.id).contains(marker), "the Claude prompt carries the idea and its notes")
            let project = store.promoteIdea(idea.id, startNow: true)
            let steps = store.children(of: idea.id).filter(\.isTodo)
            check(project?.isProject == true && project?.stage == .todo && store.openProjects.contains { $0.id == idea.id }
                  && !store.ideas.contains { $0.id == idea.id }, "Start Now makes the idea an active project")
            check(steps.map(\.title) == ["Pick a name", "Draft the first issue"] && steps[0].isDueToday && !steps[1].isDueToday,
                  "its checkboxes become to-dos, the first one in Today")
            store.undoManager.undo()
            check(store.task(idea.id)?.isIdea == true && store.task(idea.id)?.notes == notes && store.children(of: idea.id).filter { $0.status != .trashed }.isEmpty,
                  "one undo turns the project back into the idea")
            let later = store.promoteIdea(idea.id, startNow: false)
            check(later?.bucket == .someday && later?.stage == .backlog && store.children(of: idea.id).filter(\.isTodo).allSatisfy { $0.bucket == .someday },
                  "Save for Someday parks it as a planned project")
            let viaAPI = try? ThingsAPI.addIdea(["title": marker + " api idea", "notes": "From Claude", "stage": "ready", "source": "selftest"])
            check(viaAPI?.isIdea == true && viaAPI?.ideaStage == .ready && ThingsAPI.encode(viaAPI!)["type"] as? String == "idea"
                  && ThingsAPI.encode(viaAPI!)["list"] as? String == "ideas", "API adds an idea")
            if let viaAPI {
                let updated = try? ThingsAPI.update(["id": viaAPI.id, "append_notes": "## Research\n- [ ] Call Sam", "stage": "researching"])
                check(updated?.notes.hasSuffix("- [ ] Call Sam") == true && updated?.ideaStage == .researching, "API appends research to an idea")
                check((try? ThingsAPI.update(["id": task.id, "stage": "ready"])) == nil, "stage is refused on a to-do")
                let started = try? ThingsAPI.startIdea(viaAPI.id, someday: false)
                check(started?.isProject == true && (try? ThingsAPI.startIdea(viaAPI.id, someday: false)) == nil, "API starts an idea once")
                for child in store.children(of: viaAPI.id) { store.deletePermanently(child.id) }
                store.deletePermanently(viaAPI.id)
            }
            check((try? ThingsAPI.list("ideas")) != nil, "ideas is a list the API knows")
            for child in store.children(of: idea.id) { store.deletePermanently(child.id) }
            store.deletePermanently(idea.id)
        }
        do {
            let timed = store.createTask(title: marker + " timed", notes: "", bucket: .anytime)
            let entry = store.logTime(timed.id, seconds: 40 * 60, source: "selftest")
            store.logTime(timed.id, seconds: 20 * 60)
            check(store.trackedTime(timed.id) == 3600 && store.timeEntries(for: timed.id).count == 2, "time entries add up on a to-do")
            check(Duration.text(seconds: 3600) == "1h" && Duration.text(seconds: 4800) == "1h 20m" && Duration.text(seconds: 2400) == "40m", "durations read as 40m, 1h, 1h 20m")
            check(ThingsAPI.encode(store.task(timed.id)!)["tracked_minutes"] as? Int == 60, "API tasks carry tracked_minutes")
            let logged = try? ThingsAPI.logTime(timed.id, ["minutes": 15, "note": "chapter 2"], source: "plain")
            check((logged?["entry"] as? [String: Any])?["source"] as? String == "plain" && store.trackedTime(timed.id) == 75 * 60, "API logs time with its source")
            check((try? ThingsAPI.logTime(timed.id, ["minutes": 0], source: nil)) == nil, "API refuses zero minutes")
            let report = try? ThingsAPI.timeReport(["since": "today"])
            check((report?["tasks"] as? [[String: Any]])?.contains { $0["id"] as? String == timed.id } == true, "time report lists today's to-dos")
            if let entry { store.deleteTimeEntry(entry.id) }
            check(store.trackedTime(timed.id) == 35 * 60, "deleting an entry takes its time off")
            store.deletePermanently(timed.id)
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

        remindersSyncChecks(check)

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
        time("sidebar counts (\(BuiltinList.allCases.count) lists)") { for list in BuiltinList.allCases { _ = store.count(for: list) } }
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

// MARK: - Reminders sync

/// Reminders in memory, so the sync logic can be checked without touching iCloud.
final class FakeReminders: RemindersBackend {
    var hasAccess = true
    var onChange: (() -> Void)?
    var listTitles: [String: String] = [:]
    var items: [String: RemoteReminder] = [:]
    var writes = 0
    private var next = 0

    func makeID() -> String { next += 1; return "r\(next)" }
    func lists() -> [RemoteList] { listTitles.map { RemoteList(id: $0.key, title: $0.value) } }
    func fetch(listIDs: [String], completion: @escaping ([RemoteReminder]) -> Void) {
        completion(items.values.filter { listIDs.contains($0.listID) })
    }
    func createList(title: String, color: NSColor) -> String? { let id = makeID(); listTitles[id] = title; writes += 1; return id }
    func renameList(_ id: String, to title: String) { listTitles[id] = title; writes += 1 }
    func deleteList(_ id: String) { listTitles[id] = nil; items = items.filter { $0.value.listID != id }; writes += 1 }
    func save(_ reminder: RemoteReminder) -> String? {
        var saved = reminder
        if saved.id.isEmpty { saved.id = makeID() }
        saved.modified = Date()
        items[saved.id] = saved
        writes += 1
        return saved.id
    }
    func delete(_ id: String) { items[id] = nil; writes += 1 }
    func commit() {}

    /// An edit made "on the phone", a moment after everything else.
    func edit(_ id: String, _ change: (inout RemoteReminder) -> Void) {
        guard var item = items[id] else { return }
        change(&item)
        item.modified = Date().addingTimeInterval(2)
        items[id] = item
    }
    func reminder(for taskID: String) -> RemoteReminder? { items.values.first { $0.url == RemindersSync.urlPrefix + taskID } }
    func listID(named title: String) -> String? { listTitles.first { $0.value == title }?.key }
}

extension SelfTest {
    static func remindersSyncChecks(_ check: (Bool, String) -> Void) {
        let store = TaskStore.shared
        let fake = FakeReminders()
        fake.listTitles["mine"] = "Groceries"   // a list of the user's own: must stay untouched
        fake.items["own"] = RemoteReminder(id: "own", listID: "mine", title: "Milk", notes: "", due: nil, completed: false, url: nil, modified: Date())
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("things4-sync-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let sync = RemindersSync(backend: fake, stateURL: stateURL, alwaysOn: true)
        func run() { sync.sync() }

        let project = store.createProject(title: "Sync Test Project")
        let inboxTask = store.createTask(title: "Sync inbox item")
        let projectTask = store.createTask(title: "Sync project item", bucket: .anytime, projectID: project.id)
        store.setBucket(projectTask.id, bucket: .scheduled, date: Date().startOfDay.addingDays(2))

        run()
        let openTodos = store.tasks.filter { $0.isTodo && $0.isOpen }.count
        check(fake.items.values.filter { $0.url != nil }.count == openTodos, "sync: every open to-do becomes a reminder")
        check(fake.listID(named: "Inbox") != nil && fake.listID(named: "Anytime") != nil && fake.listID(named: "Sync Test Project") != nil,
              "sync: Inbox, Anytime and project lists are created")
        check(fake.items["own"]?.title == "Milk" && fake.listTitles["mine"] == "Groceries", "sync: the user's own lists are left alone")
        check(fake.reminder(for: projectTask.id)?.due == RemindersSync.dueString(store.task(projectTask.id)!), "sync: When date becomes the reminder date")

        fake.writes = 0
        run()
        check(fake.writes == 0, "sync: a second pass changes nothing (\(fake.writes) writes)")

        // Phone → Things
        if let r = fake.reminder(for: inboxTask.id) { fake.edit(r.id) { $0.completed = true; $0.title = "Renamed on phone" } }
        run()
        check(store.task(inboxTask.id)?.isCompleted == true && store.task(inboxTask.id)?.title == "Renamed on phone",
              "sync: completing and renaming on the phone updates Things")

        if let r = fake.reminder(for: projectTask.id) {
            let tomorrow = Date().startOfDay.addingDays(1)
            let at = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: tomorrow)!
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd'T'HH:mm"
            fake.edit(r.id) { $0.due = format.string(from: at) }
            run()
            check(store.task(projectTask.id)?.reminder == at && store.task(projectTask.id)?.startDate == tomorrow,
                  "sync: a time set on the phone becomes a Things reminder")
        }

        if let listID = fake.listID(named: "Sync Test Project") {
            let id = fake.makeID()
            fake.items[id] = RemoteReminder(id: id, listID: listID, title: "Added on phone", notes: "from the bus", due: nil, completed: false, url: nil, modified: Date())
            run()
            let added = store.tasks.first { $0.title == "Added on phone" }
            check(added?.projectID == project.id && added?.notes == "from the bus" && fake.items[id]?.url != nil,
                  "sync: a reminder added on the phone becomes a to-do in that project")
        }

        // Things → phone
        store.setTitle(projectTask.id, "Renamed in Things")
        run()
        check(fake.reminder(for: projectTask.id)?.title == "Renamed in Things", "sync: renaming in Things updates the reminder")

        store.move(projectTask.id, toProject: nil, areaID: nil)
        run()
        check(fake.reminder(for: projectTask.id)?.listID == fake.listID(named: "Anytime"), "sync: moving a to-do moves its reminder")

        // Deleting on the phone trashes the to-do; clearing completed ones doesn't.
        let doomed = store.createTask(title: "Delete me on phone")
        run()
        if let r = fake.reminder(for: doomed.id) { fake.delete(r.id) }
        if let r = fake.reminder(for: inboxTask.id) { fake.delete(r.id) }
        run()
        check(store.task(doomed.id)?.status == .trashed, "sync: deleting a reminder on the phone trashes the to-do")
        check(store.task(inboxTask.id)?.isCompleted == true, "sync: clearing a completed reminder keeps the to-do in the Logbook")

        // Everything vanishing at once is treated as a glitch.
        let before = store.tasks.filter { $0.status == .trashed }.count
        for item in fake.items.values where item.url != nil { fake.delete(item.id) }
        run()
        check(store.tasks.filter { $0.status == .trashed }.count == before, "sync: a mass disappearance trashes nothing")
        check(fake.items.values.filter { $0.url != nil && !$0.completed }.count == store.tasks.filter { $0.isTodo && $0.isOpen }.count,
              "sync: …and the reminders are restored")

        // A finished project's list goes away without touching its to-dos.
        store.moveToTrash(project.id)
        run()
        check(fake.listID(named: "Sync Test Project") == nil, "sync: a trashed project's list is removed")
        fake.writes = 0
        run()
        check(fake.writes == 0, "sync: settles with no further writes (\(fake.writes))")
    }
}
