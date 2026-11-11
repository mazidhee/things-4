import Foundation
import AppKit

extension Notification.Name {
    static let storeDidChange = Notification.Name("Things4.storeDidChange")
    static let selectionDidChange = Notification.Name("Things4.selectionDidChange")
    static let aiPanelToggle = Notification.Name("Things4.aiPanelToggle")
    static let sidebarToggle = Notification.Name("Things4.sidebarToggle")
    static let focusQuickAdd = Notification.Name("Things4.focusQuickAdd")
    static let focusSearch = Notification.Name("Things4.focusSearch")
    static let newTask = Notification.Name("Things4.newTask")
    static let newHeading = Notification.Name("Things4.newHeading")
    static let newProject = Notification.Name("Things4.newProject")
    static let aiEnhanceTask = Notification.Name("Things4.aiEnhanceTask")
    static let aiSettingsChanged = Notification.Name("Things4.aiSettingsChanged")
    static let openTask = Notification.Name("Things4.openTask")
    static let aiDemo = Notification.Name("Things4.aiDemo")
}

final class TaskStore {
    static let shared = TaskStore()

    private(set) var tasks: [TaskItem] = []
    private(set) var areas: [Area] = []
    /// Explicit tag colours chosen by the user (defaults come from TagColor.defaultColor).
    private(set) var tagColorMap: [String: TagColor] = [:]
    /// Seconds of focus logged against each to-do (see `logTime`).
    private(set) var trackedSeconds: [String: Int] = [:]
    /// Tags that exist without any to-do yet (created in the Tags window).
    private(set) var extraTags: Set<String> = []

    let undoManager = UndoManager()

    private let db: Database
    private let calendar = Calendar.current
    private var suppressNotifications = true

    private init() {
        let override = ProcessInfo.processInfo.environment["THINGS4_DB"] ?? ""
        let url: URL
        if !override.isEmpty {
            url = URL(fileURLWithPath: override)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Things4", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            url = support.appendingPathComponent("things4.sqlite")
        }

        do {
            db = try Database(path: url.path)
        } catch {
            fatalError("Things 4 could not open its database: \(error.localizedDescription)")
        }

        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        createSchema()
        loadAll()
        if tasks.isEmpty && areas.isEmpty { seed() }
        suppressNotifications = false
    }

    private var batchDepth = 0
    private var batchDirty = false

    /// Every change is its own undo step. Inside `batch` (or while undoing) the
    /// registration joins the open group; otherwise it gets a group of its own.
    private var pendingActionName = "Edit"

    private func registerStep(_ handler: @escaping (TaskStore) -> Void) {
        if undoManager.isUndoing || undoManager.isRedoing || undoManager.groupingLevel > 0 {
            undoManager.registerUndo(withTarget: self, handler: handler)
        } else {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self, handler: handler)
            undoManager.setActionName(pendingActionName)
            undoManager.endUndoGrouping()
        }
    }

    private func notifyStoreChange() {
        guard !suppressNotifications else { return }
        if batchDepth > 0 {
            batchDirty = true
            return
        }
        NotificationCenter.default.post(name: .storeDidChange, object: nil)
    }

    /// Groups several edits into one undo step and one UI refresh.
    func batch(_ name: String? = nil, _ body: () -> Void) {
        batchDepth += 1
        undoManager.beginUndoGrouping()
        body()
        if let name { undoManager.setActionName(name) }
        undoManager.endUndoGrouping()
        batchDepth -= 1
        if batchDepth == 0 && batchDirty {
            batchDirty = false
            NotificationCenter.default.post(name: .storeDidChange, object: nil)
        }
    }

    var databasePath: String { db.path }

    // MARK: - Schema

    private func createSchema() {
        try? db.run("""
        CREATE TABLE IF NOT EXISTS areas (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            idx INTEGER NOT NULL DEFAULT 0,
            created REAL NOT NULL
        );
        """)
        try? db.run("""
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'open',
            bucket TEXT NOT NULL DEFAULT 'inbox',
            start_date REAL,
            deadline REAL,
            project_id TEXT,
            area_id TEXT,
            heading_id TEXT,
            idx INTEGER NOT NULL DEFAULT 0,
            created REAL NOT NULL,
            modified REAL NOT NULL,
            completed_at REAL
        );
        """)
        try? db.run("CREATE TABLE IF NOT EXISTS tags (task_id TEXT NOT NULL, name TEXT NOT NULL);")
        try? db.run("CREATE TABLE IF NOT EXISTS tag_meta (name TEXT PRIMARY KEY, color TEXT NOT NULL DEFAULT 'none');")
        try? db.run("CREATE INDEX IF NOT EXISTS idx_tags_task ON tags(task_id);")
        try? db.run("""
        CREATE TABLE IF NOT EXISTS checklist (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            title TEXT NOT NULL,
            done INTEGER NOT NULL DEFAULT 0,
            idx INTEGER NOT NULL DEFAULT 0
        );
        """)
        try? db.run("CREATE INDEX IF NOT EXISTS idx_checklist_task ON checklist(task_id);")

        // Migrations. ALTER TABLE fails harmlessly when the column already exists.
        let columns = ((try? db.query("PRAGMA table_info(tasks)")) ?? []).compactMap { $0["name"] as? String }
        if !columns.contains("evening") {
            try? db.run("ALTER TABLE tasks ADD COLUMN evening INTEGER NOT NULL DEFAULT 0;")
        }
        if !columns.contains("repeat_rule") {
            try? db.run("ALTER TABLE tasks ADD COLUMN repeat_rule TEXT;")
        }
        if !columns.contains("reminder") {
            try? db.run("ALTER TABLE tasks ADD COLUMN reminder REAL;")
        }
        if !columns.contains("stage") {
            try? db.run("ALTER TABLE tasks ADD COLUMN stage TEXT NOT NULL DEFAULT 'todo';")
            try? db.run("ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;")
            try? db.run("ALTER TABLE tasks ADD COLUMN estimate INTEGER NOT NULL DEFAULT 0;")
            try? db.run("ALTER TABLE tasks ADD COLUMN waiting_on TEXT;")
            try? db.run("ALTER TABLE tasks ADD COLUMN blocked_by TEXT;")
            // Someday to-dos start out as Backlog; everything else is Todo.
            try? db.run("UPDATE tasks SET stage = 'backlog' WHERE type = 'todo' AND bucket = 'someday';")
        }
        if !columns.contains("idea_stage") {
            try? db.run("ALTER TABLE tasks ADD COLUMN idea_stage TEXT;")
        }
        try? db.run("""
        CREATE TABLE IF NOT EXISTS time_entries (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            start REAL NOT NULL,
            end REAL NOT NULL,
            seconds INTEGER NOT NULL,
            source TEXT,
            note TEXT
        );
        """)
        try? db.run("CREATE INDEX IF NOT EXISTS idx_time_task ON time_entries(task_id);")
    }

    // MARK: - Loading

    private func loadAll() {
        tagColorMap = [:]
        for row in (try? db.query("SELECT name, color FROM tag_meta")) ?? [] {
            if let name = row["name"] as? String, let raw = row["color"] as? String, let color = TagColor(rawValue: raw) {
                tagColorMap[name] = color
            }
        }
        areas = (try? db.query("SELECT * FROM areas ORDER BY idx, title"))?.compactMap { row in
            guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
            return Area(id: id, title: title,
                        index: row["idx"] as? Int ?? 0,
                        createdAt: Date(timeIntervalSince1970: row["created"] as? Double ?? 0))
        } ?? []

        trackedSeconds = [:]
        for row in (try? db.query("SELECT task_id, SUM(seconds) AS total FROM time_entries GROUP BY task_id")) ?? [] {
            if let taskID = row["task_id"] as? String { trackedSeconds[taskID] = row["total"] as? Int ?? 0 }
        }

        let tagRows = (try? db.query("SELECT task_id, name FROM tags")) ?? []
        var tagsByTask: [String: [String]] = [:]
        for row in tagRows {
            guard let taskID = row["task_id"] as? String, let name = row["name"] as? String else { continue }
            tagsByTask[taskID, default: []].append(name)
        }

        let checklistRows = (try? db.query("SELECT * FROM checklist ORDER BY idx")) ?? []
        var checklistByTask: [String: [ChecklistItem]] = [:]
        for row in checklistRows {
            guard let taskID = row["task_id"] as? String,
                  let id = row["id"] as? String,
                  let title = row["title"] as? String else { continue }
            let item = ChecklistItem(id: id, title: title,
                                     done: (row["done"] as? Int ?? 0) == 1,
                                     index: row["idx"] as? Int ?? 0)
            checklistByTask[taskID, default: []].append(item)
        }

        tasks = (try? db.query("SELECT * FROM tasks"))?.compactMap { row in
            guard let id = row["id"] as? String,
                  let title = row["title"] as? String else { return nil }
            let type = TaskType(rawValue: row["type"] as? String ?? "todo") ?? .todo
            let status = TaskStatus(rawValue: row["status"] as? String ?? "open") ?? .open
            let bucket = StartBucket(rawValue: row["bucket"] as? String ?? "inbox") ?? .inbox
            let start = (row["start_date"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let deadline = (row["deadline"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let completed = (row["completed_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return TaskItem(
                id: id,
                type: type,
                title: title,
                notes: row["notes"] as? String ?? "",
                status: status,
                bucket: bucket,
                startDate: start,
                deadline: deadline,
                projectID: row["project_id"] as? String,
                areaID: row["area_id"] as? String,
                headingID: row["heading_id"] as? String,
                index: row["idx"] as? Int ?? 0,
                createdAt: Date(timeIntervalSince1970: row["created"] as? Double ?? 0),
                modifiedAt: Date(timeIntervalSince1970: row["modified"] as? Double ?? 0),
                completedAt: completed,
                tags: (tagsByTask[id] ?? []).sorted(),
                checklist: (checklistByTask[id] ?? []).sorted { $0.index < $1.index },
                isEvening: (row["evening"] as? Int ?? 0) == 1,
                repeatRule: RepeatRule.decode(row["repeat_rule"] as? String),
                reminder: (row["reminder"] as? Double).map { Date(timeIntervalSince1970: $0) },
                stage: Stage(rawValue: row["stage"] as? String ?? "todo") ?? .todo,
                priority: Priority(rawValue: row["priority"] as? Int ?? 0) ?? .none,
                estimate: row["estimate"] as? Int ?? 0,
                waitingOn: row["waiting_on"] as? String,
                blockedBy: row["blocked_by"] as? String,
                ideaStage: IdeaStage(rawValue: row["idea_stage"] as? String ?? "") ?? .raw
            )
        } ?? []
    }

    // MARK: - Writes

    private func persist(_ task: TaskItem) {
        do {
            try db.run("""
        INSERT INTO tasks (id, type, title, notes, status, bucket, start_date, deadline,
                           project_id, area_id, heading_id, idx, created, modified, completed_at,
                           evening, repeat_rule, reminder, stage, priority, estimate, waiting_on, blocked_by, idea_stage)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            type=excluded.type, title=excluded.title, notes=excluded.notes, status=excluded.status,
            bucket=excluded.bucket, start_date=excluded.start_date, deadline=excluded.deadline,
            project_id=excluded.project_id, area_id=excluded.area_id, heading_id=excluded.heading_id,
            idx=excluded.idx, created=excluded.created, modified=excluded.modified,
            completed_at=excluded.completed_at, evening=excluded.evening, repeat_rule=excluded.repeat_rule,
            reminder=excluded.reminder, stage=excluded.stage, priority=excluded.priority,
            estimate=excluded.estimate, waiting_on=excluded.waiting_on, blocked_by=excluded.blocked_by,
            idea_stage=excluded.idea_stage;
        """, [
            task.id, task.type.rawValue, task.title, task.notes, task.status.rawValue,
            task.bucket.rawValue, task.startDate?.timeIntervalSince1970, task.deadline?.timeIntervalSince1970,
            task.projectID, task.areaID, task.headingID, task.index,
            task.createdAt.timeIntervalSince1970, task.modifiedAt.timeIntervalSince1970,
            task.completedAt?.timeIntervalSince1970,
            task.isEvening ? 1 : 0, task.repeatRule?.encoded, task.reminder?.timeIntervalSince1970,
            task.stage.rawValue, task.priority.rawValue, task.estimate, task.waitingOn, task.blockedBy,
            task.isIdea ? task.ideaStage.rawValue : nil
            ])
        } catch {
            NSLog("Things 4 persist failed: \(error.localizedDescription)")
        }
        try? db.run("DELETE FROM tags WHERE task_id = ?", [task.id])
        for tag in task.tags where !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            try? db.run("INSERT INTO tags (task_id, name) VALUES (?, ?)", [task.id, tag])
        }
        try? db.run("DELETE FROM checklist WHERE task_id = ?", [task.id])
        for (position, item) in task.checklist.enumerated() {
            try? db.run("INSERT INTO checklist (id, task_id, title, done, idx) VALUES (?, ?, ?, ?, ?)",
                        [item.id, task.id, item.title, item.done ? 1 : 0, position])
        }
    }

    // MARK: - Undo

    /// Restores a task to a previous snapshot (or removes it when the snapshot is nil).
    /// Registered with the undo manager so every edit can be undone with ⌘Z.
    private func restore(snapshot: TaskItem?, id: String, actionName: String) {
        let current = task(id)
        pendingActionName = actionName
        registerStep { store in
            store.restore(snapshot: current, id: id, actionName: actionName)
        }
        if undoManager.groupingLevel > 0 { undoManager.setActionName(actionName) }
        if let snapshot {
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index] = snapshot
            } else {
                tasks.append(snapshot)
            }
            persist(snapshot)
        } else {
            try? db.run("DELETE FROM tags WHERE task_id = ?", [id])
            try? db.run("DELETE FROM checklist WHERE task_id = ?", [id])
            try? db.run("DELETE FROM tasks WHERE id = ?", [id])
            tasks.removeAll { $0.id == id }
        }
        notifyStoreChange()
    }

    /// Anything the user schedules for today in the app is "seen"; only to-dos that
    /// arrive on their own (a start date passing, a repeat) show as new.
    private func markSeenIfUserScheduledToday(_ task: TaskItem) {
        guard !suppressNotifications, task.isTodo, task.isDueToday, Bundle.main.bundleIdentifier != nil else { return }
        var seen = Preferences.seenToday
        if seen.insert(task.id).inserted { Preferences.seenToday = seen }
    }

    private func commit(_ task: TaskItem, actionName: String = "Edit") {
        markSeenIfUserScheduledToday(task)
        var updated = task
        updated.modifiedAt = Date()
        let previous = self.task(task.id)
        pendingActionName = actionName
        registerStep { store in
            store.restore(snapshot: previous, id: updated.id, actionName: actionName)
        }
        if undoManager.groupingLevel > 0 { undoManager.setActionName(actionName) }
        if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[index] = updated
        } else {
            tasks.append(updated)
        }
        persist(updated)
        notifyStoreChange()
    }

    private func insert(_ task: TaskItem, actionName: String) {
        if actionName != "Complete" { markSeenIfUserScheduledToday(task) }
        pendingActionName = actionName
        registerStep { store in
            store.restore(snapshot: nil, id: task.id, actionName: actionName)
        }
        if undoManager.groupingLevel > 0 { undoManager.setActionName(actionName) }
        tasks.append(task)
        persist(task)
        notifyStoreChange()
    }

    // MARK: - Task creation

    @discardableResult
    func createTask(title: String, notes: String = "", bucket: StartBucket = .inbox,
                    startDate: Date? = nil, deadline: Date? = nil,
                    projectID: String? = nil, areaID: String? = nil, headingID: String? = nil,
                    tags: [String] = [], checklist: [String] = [], isEvening: Bool = false,
                    afterTaskID: String? = nil) -> TaskItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let maxIndex = tasks.filter { $0.projectID == projectID || (projectID == nil && $0.areaID == areaID) }
            .map(\.index).max() ?? -1
        var task = TaskItem(
            id: TaskItem.newID(),
            type: .todo,
            title: trimmed.isEmpty ? "New To-Do" : trimmed,
            notes: notes,
            status: .open,
            bucket: bucket,
            startDate: startDate,
            deadline: deadline,
            projectID: projectID,
            areaID: areaID,
            headingID: headingID,
            index: maxIndex + 1,
            createdAt: now,
            modifiedAt: now,
            completedAt: nil,
            tags: tags.filter { !$0.isEmpty },
            checklist: checklist.enumerated().map {
                ChecklistItem(id: TaskItem.newID(), title: $0.element, done: false, index: $0.offset)
            },
            isEvening: isEvening
        )
        if bucket == .scheduled && startDate == nil { task.startDate = Date().startOfDay }
        if let afterTaskID, let anchor = self.task(afterTaskID) {
            task.index = anchor.index + 1
            task.headingID = anchor.headingID
            // Shift everything after the anchor down by one.
            batch("New To-Do") {
                for sibling in tasks where sibling.id != anchor.id && sibling.index > anchor.index &&
                    sibling.projectID == anchor.projectID && sibling.areaID == anchor.areaID {
                    var moved = sibling
                    moved.index += 1
                    commit(moved, actionName: "New To-Do")
                }
                insert(task, actionName: "New To-Do")
            }
        } else {
            insert(task, actionName: "New To-Do")
        }
        return task
    }

    @discardableResult
    func createProject(title: String, notes: String = "", areaID: String? = nil) -> TaskItem {
        let now = Date()
        let maxIndex = tasks.filter { $0.isProject && $0.areaID == areaID }.map(\.index).max() ?? -1
        let task = TaskItem(
            id: TaskItem.newID(), type: .project,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Project" : title,
            notes: notes, status: .open, bucket: .anytime, startDate: nil, deadline: nil,
            projectID: nil, areaID: areaID, headingID: nil, index: maxIndex + 1,
            createdAt: now, modifiedAt: now, completedAt: nil, tags: [], checklist: []
        )
        insert(task, actionName: "New Project")
        return task
    }

    // MARK: - Ideas

    @discardableResult
    func createIdea(title: String, notes: String = "", areaID: String? = nil, stage: IdeaStage = .raw) -> TaskItem {
        let now = Date()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var idea = TaskItem(
            id: TaskItem.newID(), type: .idea, title: trimmed.isEmpty ? "New Idea" : trimmed,
            notes: notes, status: .open, bucket: .someday, startDate: nil, deadline: nil,
            projectID: nil, areaID: areaID, headingID: nil, index: (ideas.map(\.index).max() ?? -1) + 1,
            createdAt: now, modifiedAt: now, completedAt: nil, tags: [], checklist: []
        )
        idea.ideaStage = stage
        insert(idea, actionName: "New Idea")
        return idea
    }

    /// Open ideas, most recently touched first.
    var ideas: [TaskItem] {
        tasks.filter { $0.isIdea && $0.isOpen }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func setIdeaStage(_ id: String, _ stage: IdeaStage) {
        guard var idea = task(id), idea.isIdea, idea.ideaStage != stage else { return }
        idea.ideaStage = stage
        commit(idea, actionName: "Set Stage")
    }

    /// Turns an idea into a project. Open checkboxes in its notes (`- [ ] …`) become
    /// the project's to-dos and leave the notes; everything else stays as the project's notes.
    /// Starting now makes the project Active and plans its first to-do for today;
    /// otherwise it goes to Someday as Planned.
    @discardableResult
    func promoteIdea(_ id: String, startNow: Bool) -> TaskItem? {
        guard var project = task(id), project.isIdea else { return nil }
        let (notes, steps) = Self.extractSteps(from: project.notes)
        batch(startNow ? "Start Project" : "Move to Someday") {
            project.type = .project
            project.notes = notes
            project.bucket = startNow ? .anytime : .someday
            project.stage = startNow ? .todo : .backlog
            project.index = (tasks.filter { $0.isProject && $0.areaID == project.areaID }.map(\.index).max() ?? -1) + 1
            commit(project, actionName: startNow ? "Start Project" : "Move to Someday")
            for (position, step) in steps.enumerated() {
                let first = startNow && position == 0
                createTask(title: step, bucket: first ? .scheduled : (startNow ? .anytime : .someday),
                           startDate: first ? Date().startOfDay : nil, projectID: project.id, areaID: project.areaID)
            }
        }
        return task(id)
    }

    /// Splits `- [ ] step` lines out of Markdown notes.
    static func extractSteps(from notes: String) -> (notes: String, steps: [String]) {
        var kept: [String] = []
        var steps: [String] = []
        for line in notes.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = ["- [ ] ", "* [ ] ", "- [] "].lazy.compactMap({ trimmed.hasPrefix($0) ? $0.count : nil }).first {
                let step = String(trimmed.dropFirst(range)).trimmingCharacters(in: .whitespaces)
                if !step.isEmpty { steps.append(step); continue }
            }
            kept.append(line)
        }
        // Collapse the blank runs left where a checklist used to be.
        var result: [String] = []
        for line in kept where !(line.trimmingCharacters(in: .whitespaces).isEmpty && (result.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)) {
            result.append(line)
        }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        return (result.joined(separator: "\n"), steps)
    }

    /// An idea as a prompt for a research chat with Claude.
    func ideaPrompt(_ id: String) -> String {
        guard let idea = task(id) else { return "" }
        var text = "I'm thinking about a project idea and would like help researching it.\n\n# \(idea.title)\n"
        if let areaID = idea.areaID, let area = area(areaID) { text += "\nArea of my life: \(area.title)\n" }
        text += "Stage: \(idea.ideaStage.title)\n"
        let notes = idea.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        text += notes.isEmpty ? "\nNo notes yet.\n" : "\n## My notes so far\n\n\(notes)\n"
        text += "\nHelp me work out whether and how to do this: open questions, prior art, a rough plan, and the first concrete steps. "
        text += "Write the steps as a Markdown checklist (- [ ] step) so I can paste them back; they become to-dos when I start the project."
        return text
    }

    /// A heading (section) inside a project, or directly inside an area.
    @discardableResult
    func createHeading(title: String, projectID: String? = nil, areaID: String? = nil) -> TaskItem {
        let now = Date()
        let siblings = tasks.filter { projectID != nil ? $0.projectID == projectID : ($0.projectID == nil && $0.areaID == areaID) }
        let maxIndex = siblings.map(\.index).max() ?? -1
        let task = TaskItem(
            id: TaskItem.newID(), type: .heading,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Heading" : title,
            notes: "", status: .open, bucket: .anytime, startDate: nil, deadline: nil,
            projectID: projectID, areaID: projectID.flatMap { self.task($0)?.areaID } ?? areaID, headingID: nil, index: maxIndex + 1,
            createdAt: now, modifiedAt: now, completedAt: nil, tags: [], checklist: []
        )
        insert(task, actionName: "New Heading")
        return task
    }

    /// Things' "Convert to Project": a to-do's checklist becomes the project's to-dos;
    /// a heading's to-dos move into the new project.
    @discardableResult
    func convertToProject(_ id: String) -> TaskItem? {
        guard let source = task(id), source.isTodo || source.isHeading else { return nil }
        var project: TaskItem?
        batch("Convert to Project") {
            let areaID = source.areaID ?? source.projectID.flatMap { self.task($0)?.areaID }
            let created = createProject(title: source.title, notes: source.notes, areaID: areaID)
            project = created
            if source.isTodo {
                for item in source.checklist {
                    createTask(title: item.title, bucket: .anytime, projectID: created.id, areaID: areaID)
                }
            } else {
                for child in tasks where child.headingID == id {
                    var moved = child
                    moved.projectID = created.id
                    moved.headingID = nil
                    moved.areaID = areaID
                    commit(moved, actionName: "Convert to Project")
                }
            }
            moveToTrash(id)
        }
        return project
    }

    /// Headings that sit directly in an area (not inside a project).
    func headings(inArea areaID: String) -> [TaskItem] {
        tasks.filter { $0.isHeading && $0.projectID == nil && $0.areaID == areaID && $0.status != .trashed }
            .sorted { $0.index < $1.index }
    }

    /// Completes every open to-do under a heading, then archives the heading (Things' "Archive").
    func archiveHeading(_ id: String) {
        batch("Archive Heading") {
            for child in tasks where child.headingID == id && child.isOpen && child.isTodo {
                complete(child.id, status: .completed)
            }
            if var heading = task(id) {
                heading.status = .completed
                heading.completedAt = Date()
                commit(heading, actionName: "Archive Heading")
            }
        }
    }

    @discardableResult
    func createArea(title: String) -> Area {
        let area = Area(id: TaskItem.newID(), title: title, index: areas.count, createdAt: Date())
        areas.append(area)
        try? db.run("INSERT INTO areas (id, title, idx, created) VALUES (?, ?, ?, ?)",
                    [area.id, area.title, area.index, area.createdAt.timeIntervalSince1970])
        notifyStoreChange()
        return area
    }

    func renameArea(_ id: String, to title: String) {
        guard let index = areas.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        areas[index].title = trimmed
        try? db.run("UPDATE areas SET title = ? WHERE id = ?", [trimmed, id])
        notifyStoreChange()
    }

    /// Deletes an area. Its projects and to-dos are kept and simply lose the area.
    func deleteArea(_ id: String) {
        batch("Delete Area") {
            for item in tasks where item.areaID == id {
                var moved = item
                moved.areaID = nil
                commit(moved, actionName: "Delete Area")
            }
            areas.removeAll { $0.id == id }
            try? db.run("DELETE FROM areas WHERE id = ?", [id])
            notifyStoreChange()
        }
    }

    @discardableResult
    func duplicate(_ id: String) -> TaskItem? {
        guard let source = task(id) else { return nil }
        var copy = source
        copy.id = TaskItem.newID()
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        copy.status = .open
        copy.completedAt = nil
        copy.index = source.index + 1
        copy.checklist = source.checklist.map {
            ChecklistItem(id: TaskItem.newID(), title: $0.title, done: false, index: $0.index)
        }
        batch("Duplicate") {
            for sibling in tasks where sibling.id != source.id && sibling.index > source.index &&
                sibling.projectID == source.projectID && sibling.areaID == source.areaID {
                var moved = sibling
                moved.index += 1
                commit(moved, actionName: "Duplicate")
            }
            insert(copy, actionName: "Duplicate")
            if source.isProject {
                for child in children(of: source.id) {
                    var childCopy = child
                    childCopy.id = TaskItem.newID()
                    childCopy.projectID = copy.id
                    childCopy.status = .open
                    childCopy.completedAt = nil
                    childCopy.checklist = child.checklist.map {
                        ChecklistItem(id: TaskItem.newID(), title: $0.title, done: false, index: $0.index)
                    }
                    insert(childCopy, actionName: "Duplicate")
                }
            }
        }
        return copy
    }

    // MARK: - Updates

    func update(_ task: TaskItem) {
        commit(task)
    }

    func renameProject(_ id: String, to title: String) {
        guard var project = task(id) else { return }
        project.title = title.isEmpty ? project.title : title
        commit(project, actionName: "Rename")
    }

    func setTitle(_ id: String, _ title: String) {
        guard var task = task(id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return }
        task.title = trimmed
        commit(task, actionName: "Rename")
    }

    func setNotes(_ id: String, _ notes: String) {
        guard var task = task(id), task.notes != notes else { return }
        task.notes = notes
        commit(task, actionName: "Edit Notes")
    }

    func setTags(_ id: String, _ tags: [String]) {
        guard var task = task(id) else { return }
        task.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespaces) })).filter { !$0.isEmpty }.sorted()
        commit(task, actionName: "Edit Tags")
    }

    func toggleCompletion(_ id: String) {
        guard let task = task(id) else { return }
        if task.isCompleted {
            reopen(id)
        } else {
            complete(id, status: .completed)
        }
    }

    func cancel(_ id: String) {
        guard let task = task(id), !task.isCompleted else { return }
        complete(id, status: .canceled)
    }

    func reopen(_ id: String) {
        guard var task = task(id), task.isCompleted else { return }
        task.status = .open
        task.completedAt = nil
        if task.stage == .waiting && task.waitingOn == nil && task.blockedBy == nil { task.stage = .todo }
        commit(task, actionName: "Reopen")
    }

    // MARK: - Day plan

    private var plannedIDs: Set<String> = []
    private var plannedDay: Date?
    private var plannedLoaded = false
    /// A scratch database (tests, snapshots) never touches the saved plan.
    private let persistsPlan = ProcessInfo.processInfo.environment["THINGS4_DB"] == nil

    /// The to-dos today's plan put first. Forgotten when the day rolls over.
    var plannedToday: Set<String> {
        if !plannedLoaded {
            plannedLoaded = true
            if persistsPlan, let parts = UserDefaults.standard.string(forKey: "plan.today")?.split(separator: "|", maxSplits: 1).map(String.init), parts.count == 2 {
                plannedDay = Date.fromISO(parts[0])
                plannedIDs = Set(parts[1].split(separator: ",").map(String.init))
            }
        }
        return plannedDay == Date().startOfDay ? plannedIDs : []
    }

    func setPlannedToday(_ ids: [String]) {
        plannedLoaded = true
        plannedDay = Date().startOfDay
        plannedIDs = Set(ids)
        if persistsPlan { UserDefaults.standard.set(Date().startOfDay.isoString + "|" + ids.joined(separator: ","), forKey: "plan.today") }
        notifyStoreChange()
    }

    // MARK: - Workflow

    /// Moves to-dos through the six statuses. Done and Canceled go through the
    /// usual completion path so repeats, the Logbook and undo behave the same.
    func setFlow(_ id: String, _ flow: Flow) {
        guard let task = task(id), task.status != .trashed, task.flow != flow else { return }
        guard let stage = flow.stage else {
            batch(flow == .canceled ? "Cancel" : "Complete") {
                if task.isCompleted { reopen(id) }
                complete(id, status: flow == .canceled ? .canceled : .completed)
            }
            return
        }
        batch("Set Status") {
            if task.isCompleted { reopen(id) }
            setStage(id, stage)
        }
    }

    func setStage(_ id: String, _ stage: Stage) {
        guard var task = task(id), task.stage != stage else { return }
        if task.stage == .waiting {
            task.waitingOn = nil
            task.blockedBy = nil
        }
        task.stage = stage
        // Starting a to-do plans it for today.
        if stage == .progress, task.isTodo, task.isOpen, !task.isDueToday,
           task.bucket != .scheduled || task.startDate == nil {
            task.bucket = .scheduled
            task.startDate = Date().startOfDay
        }
        commit(task, actionName: "Set Status")
    }

    func setPriority(_ id: String, _ priority: Priority) {
        guard var task = task(id), task.priority != priority else { return }
        task.priority = priority
        commit(task, actionName: "Set Priority")
    }

    func setEstimate(_ id: String, minutes: Int) {
        guard var task = task(id), task.estimate != max(0, minutes) else { return }
        task.estimate = max(0, minutes)
        commit(task, actionName: "Set Estimate")
    }

    /// Marks a to-do as Waiting on a person or thing (`on`) or on another to-do (`blockedBy`).
    func setWaiting(_ id: String, on text: String? = nil, blockedBy: String? = nil) {
        guard var task = task(id), blockedBy != id else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        task.stage = .waiting
        task.waitingOn = (trimmed?.isEmpty ?? true) ? nil : trimmed
        task.blockedBy = blockedBy.flatMap { self.task($0)?.isOpen == true ? $0 : nil }
        commit(task, actionName: "Set Waiting")
    }

    /// "Waiting on Henry" or "Blocked by Demo video"; nil when there is nothing to say.
    func waitingLabel(_ task: TaskItem) -> String? {
        guard task.isOpen, task.stage == .waiting else { return nil }
        if let blocker = task.blockedBy.flatMap({ self.task($0) }), blocker.isOpen { return "Blocked by " + blocker.title }
        if let on = task.waitingOn, !on.isEmpty { return "Waiting on " + on }
        return nil
    }

    /// Every to-do in an area, including the ones inside its projects.
    func areaTodos(_ areaID: String) -> [TaskItem] {
        let projectIDs = Set(projects(inArea: areaID).filter(\.isOpen).map(\.id))
        return tasks.filter {
            guard $0.isTodo, $0.status != .trashed else { return false }
            if let projectID = $0.projectID { return projectIDs.contains(projectID) }
            return $0.areaID == areaID
        }.sorted { $0.index < $1.index }
    }

    /// Open to-do counts per status for a set of to-dos, plus estimate and focus totals.
    func estimateTotal(_ items: [TaskItem]) -> Int { items.reduce(0) { $0 + $1.estimate } }
    func trackedTotal(_ items: [TaskItem]) -> Int { items.reduce(0) { $0 + (trackedSeconds[$1.id] ?? 0) } }

    private func complete(_ id: String, status: TaskStatus) {
        guard var task = task(id) else { return }
        task.status = status
        task.completedAt = Date()
        batch(status == .canceled ? "Cancel" : "Complete") {
            commit(task, actionName: status == .canceled ? "Cancel" : "Complete")
            // Finishing a to-do frees whatever was blocked by it.
            for waiting in tasks where waiting.blockedBy == id && waiting.isOpen {
                var freed = waiting
                freed.blockedBy = nil
                if freed.stage == .waiting && freed.waitingOn == nil { freed.stage = .todo }
                commit(freed, actionName: "Unblock")
            }
            if task.isProject {
                for child in tasks where child.projectID == id && child.isOpen && child.isTodo {
                    var done = child
                    done.status = status
                    done.completedAt = Date()
                    commit(done, actionName: "Complete")
                }
            }
            if let rule = task.repeatRule, task.isTodo, status == .completed {
                spawnNextOccurrence(of: task, rule: rule)
            }
        }
    }

    private func spawnNextOccurrence(of task: TaskItem, rule: RepeatRule) {
        let base = rule.afterCompletion ? Date().startOfDay : (task.startDate ?? task.deadline ?? Date().startOfDay)
        var nextStart = rule.next(after: base)
        while nextStart < Date().startOfDay { nextStart = rule.next(after: nextStart) }
        var next = task
        next.id = TaskItem.newID()
        next.status = .open
        next.completedAt = nil
        next.createdAt = Date()
        next.modifiedAt = Date()
        next.checklist = task.checklist.map {
            ChecklistItem(id: TaskItem.newID(), title: $0.title, done: false, index: $0.index)
        }
        if let reminder = task.reminder { next.reminder = Self.combine(day: nextStart, timeOf: reminder) }
        if task.startDate != nil || task.deadline == nil {
            next.bucket = .scheduled
            next.startDate = nextStart
            if let deadline = task.deadline, let start = task.startDate {
                let gap = calendar.dateComponents([.day], from: start, to: deadline).day ?? 0
                next.deadline = nextStart.addingDays(gap)
            }
        } else {
            next.deadline = nextStart
        }
        insert(next, actionName: "Complete")
    }

    func setBucket(_ id: String, bucket: StartBucket, date: Date? = nil) {
        guard var task = task(id) else { return }
        task.bucket = bucket
        if bucket != .scheduled {
            task.reminder = nil
        } else if let reminder = task.reminder {
            task.reminder = Self.combine(day: date?.startOfDay ?? Date().startOfDay, timeOf: reminder)
        }
        switch bucket {
        case .inbox:
            task.startDate = nil
            task.projectID = nil
            task.headingID = nil
            task.isEvening = false
        case .anytime:
            task.startDate = nil
            task.isEvening = false
        case .someday:
            task.startDate = nil
            task.isEvening = false
        case .scheduled:
            task.startDate = date?.startOfDay ?? Date().startOfDay
            if task.startDate != Date().startOfDay { task.isEvening = false }
        }
        commit(task, actionName: "Schedule")
    }

    func setEvening(_ id: String, _ evening: Bool) {
        guard var task = task(id) else { return }
        task.isEvening = evening
        if evening {
            task.bucket = .scheduled
            task.startDate = Date().startOfDay
        }
        commit(task, actionName: "This Evening")
    }

    func shiftStart(_ id: String, days: Int) {
        guard var task = task(id) else { return }
        let base = task.startDate ?? Date().startOfDay
        task.bucket = .scheduled
        task.startDate = base.addingDays(days)
        if let reminder = task.reminder { task.reminder = reminder.addingDays(days) }
        if task.startDate != Date().startOfDay { task.isEvening = false }
        commit(task, actionName: "Schedule")
    }

    /// Sets a reminder. A reminder implies the to-do is scheduled on that day.
    func setReminder(_ id: String, at date: Date?) {
        guard var task = task(id) else { return }
        task.reminder = date
        if let date {
            task.bucket = .scheduled
            task.startDate = date.startOfDay
            if !date.isToday { task.isEvening = false }
        }
        commit(task, actionName: "Reminder")
    }

    static func combine(day: Date, timeOf time: Date) -> Date {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day) ?? day
    }

    func setDeadline(_ id: String, date: Date?) {
        guard var task = task(id) else { return }
        task.deadline = date?.startOfDay
        commit(task, actionName: "Deadline")
    }

    func shiftDeadline(_ id: String, days: Int) {
        guard var task = task(id) else { return }
        task.deadline = (task.deadline ?? Date().startOfDay).addingDays(days)
        commit(task, actionName: "Deadline")
    }

    func setRepeat(_ id: String, rule: RepeatRule?) {
        guard var task = task(id) else { return }
        task.repeatRule = rule
        if rule != nil, task.startDate == nil, task.deadline == nil {
            task.bucket = .scheduled
            task.startDate = Date().startOfDay
        }
        commit(task, actionName: "Repeat")
    }

    func move(_ id: String, toProject projectID: String?, areaID: String?, headingID: String? = nil) {
        guard var task = task(id) else { return }
        let changesContainer = task.projectID != projectID || (projectID == nil && task.areaID != areaID)
        if changesContainer { task.headingID = headingID }
        else if headingID != nil { task.headingID = headingID }
        task.projectID = projectID
        task.areaID = areaID
        if task.bucket == .inbox { task.bucket = .anytime }
        let siblings = tasks.filter { $0.id != id && $0.projectID == projectID && (projectID != nil || $0.areaID == areaID) }
        task.index = (siblings.map(\.index).max() ?? -1) + 1
        commit(task, actionName: "Move")
    }

    func setHeading(_ id: String, headingID: String?) {
        guard var task = task(id) else { return }
        task.headingID = headingID
        commit(task, actionName: "Move")
    }

    func moveToTrash(_ id: String) {
        guard var task = task(id) else { return }
        task.status = .trashed
        batch("Delete") {
            commit(task, actionName: "Delete")
            if task.isProject {
                for child in tasks where child.projectID == id && child.status != .trashed {
                    moveToTrash(child.id)
                }
            }
            if task.isHeading {
                for child in tasks where child.headingID == id {
                    var orphan = child
                    orphan.headingID = nil
                    commit(orphan, actionName: "Delete")
                }
            }
        }
    }

    func restore(_ id: String) {
        guard var task = task(id) else { return }
        task.status = .open
        task.completedAt = nil
        if let projectID = task.projectID, self.task(projectID)?.status == .trashed {
            task.projectID = nil
            task.headingID = nil
        }
        commit(task, actionName: "Restore")
    }

    func deletePermanently(_ id: String) {
        let previous = task(id)
        pendingActionName = "Delete"
        registerStep { store in
            store.restore(snapshot: previous, id: id, actionName: "Delete")
        }
        if undoManager.groupingLevel > 0 { undoManager.setActionName("Delete") }
        try? db.run("DELETE FROM tags WHERE task_id = ?", [id])
        try? db.run("DELETE FROM checklist WHERE task_id = ?", [id])
        try? db.run("DELETE FROM tasks WHERE id = ?", [id])
        tasks.removeAll { $0.id == id }
        notifyStoreChange()
    }

    // MARK: - Time tracking

    /// Logs focused time against a to-do, from the focus timer, Plain or the API.
    @discardableResult
    func logTime(_ taskID: String, seconds: Int, start: Date? = nil, end: Date? = nil, source: String? = nil,
                 note: String? = nil, id: String = UUID().uuidString) -> TimeEntry? {
        guard task(taskID) != nil, seconds > 0 else { return nil }
        let finish = end ?? Date()
        let entry = TimeEntry(id: id, taskID: taskID, start: start ?? finish.addingTimeInterval(TimeInterval(-seconds)),
                              end: finish, seconds: seconds, source: source, note: note)
        do {
            try db.run("INSERT OR REPLACE INTO time_entries (id, task_id, start, end, seconds, source, note) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       [entry.id, taskID, entry.start.timeIntervalSince1970, entry.end.timeIntervalSince1970, seconds, source, note])
        } catch {
            NSLog("Things4: couldn't log time: \(error)")
            return nil
        }
        pendingActionName = "Log Time"
        registerStep { store in store.deleteTimeEntry(entry.id) }
        trackedSeconds[taskID, default: 0] += seconds
        notifyStoreChange()
        return entry
    }

    func deleteTimeEntry(_ id: String) {
        guard let entry = timeEntries(where: "id = ?", [id]).first else { return }
        pendingActionName = "Delete Time"
        registerStep { store in
            store.logTime(entry.taskID, seconds: entry.seconds, start: entry.start, end: entry.end,
                          source: entry.source, note: entry.note, id: entry.id)
        }
        try? db.run("DELETE FROM time_entries WHERE id = ?", [id])
        trackedSeconds[entry.taskID] = max(0, (trackedSeconds[entry.taskID] ?? 0) - entry.seconds)
        notifyStoreChange()
    }

    /// A to-do's own time; a project's includes its to-dos.
    func trackedTime(_ id: String) -> Int {
        guard let item = task(id) else { return 0 }
        var total = trackedSeconds[id] ?? 0
        if item.isProject {
            for child in tasks where child.projectID == id { total += trackedSeconds[child.id] ?? 0 }
        }
        return total
    }

    func timeEntries(for taskID: String) -> [TimeEntry] {
        timeEntries(where: "task_id = ?", [taskID])
    }

    func timeEntries(since: Date) -> [TimeEntry] {
        timeEntries(where: "end >= ?", [since.timeIntervalSince1970])
    }

    private func timeEntries(where clause: String, _ params: [Any?]) -> [TimeEntry] {
        ((try? db.query("SELECT * FROM time_entries WHERE \(clause) ORDER BY start DESC", params)) ?? []).compactMap { row in
            guard let id = row["id"] as? String, let taskID = row["task_id"] as? String else { return nil }
            return TimeEntry(id: id, taskID: taskID,
                             start: Date(timeIntervalSince1970: row["start"] as? Double ?? 0),
                             end: Date(timeIntervalSince1970: row["end"] as? Double ?? 0),
                             seconds: row["seconds"] as? Int ?? 0,
                             source: row["source"] as? String, note: row["note"] as? String)
        }
    }

    func emptyTrash() {
        batch("Empty Trash") {
            for item in tasks where item.status == .trashed {
                deletePermanently(item.id)
            }
        }
    }

    func moveChecklistItem(_ taskID: String, from: Int, to: Int) {
        guard var task = task(taskID), task.checklist.indices.contains(from) else { return }
        let item = task.checklist.remove(at: from)
        task.checklist.insert(item, at: max(0, min(to, task.checklist.count)))
        for i in task.checklist.indices { task.checklist[i].index = i }
        commit(task, actionName: "Reorder Checklist")
    }

    func addChecklistItem(_ taskID: String, title: String) {
        guard var task = task(taskID), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        task.checklist.append(ChecklistItem(id: TaskItem.newID(), title: title, done: false, index: task.checklist.count))
        commit(task, actionName: "Checklist")
    }

    func toggleChecklistItem(_ taskID: String, itemID: String) {
        guard var task = task(taskID), let index = task.checklist.firstIndex(where: { $0.id == itemID }) else { return }
        task.checklist[index].done.toggle()
        commit(task, actionName: "Checklist")
    }

    func renameChecklistItem(_ taskID: String, itemID: String, title: String) {
        guard var task = task(taskID), let index = task.checklist.firstIndex(where: { $0.id == itemID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        task.checklist[index].title = trimmed
        commit(task, actionName: "Checklist")
    }

    func deleteChecklistItem(_ taskID: String, itemID: String) {
        guard var task = task(taskID) else { return }
        task.checklist.removeAll { $0.id == itemID }
        commit(task, actionName: "Checklist")
    }

    // MARK: - Ordering

    /// Re-numbers `orderedIDs` so they sort in that order inside their list.
    func reorder(_ orderedIDs: [String]) {
        batch("Reorder") {
            for (position, id) in orderedIDs.enumerated() {
                guard var item = task(id), item.index != position else { continue }
                item.index = position
                commit(item, actionName: "Reorder")
            }
        }
    }

    /// Moves `id` one step up or down among `siblings` (ordered list of IDs in the visible list).
    func nudge(_ id: String, in siblings: [String], by delta: Int) {
        guard let position = siblings.firstIndex(of: id) else { return }
        let target = position + delta
        guard target >= 0, target < siblings.count else { return }
        var ordered = siblings
        ordered.swapAt(position, target)
        reorder(ordered)
    }

    // MARK: - Reads

    private var indexByID: [String: Int] = [:]
    private var indexedCount = -1

    func task(_ id: String) -> TaskItem? {
        if indexedCount != tasks.count || (indexByID[id].map { $0 >= tasks.count || tasks[$0].id != id } ?? true) {
            indexByID = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($0.element.id, $0.offset) })
            indexedCount = tasks.count
        }
        guard let index = indexByID[id], index < tasks.count, tasks[index].id == id else { return nil }
        return tasks[index]
    }

    func area(_ id: String) -> Area? { areas.first { $0.id == id } }

    func projects(inArea areaID: String?) -> [TaskItem] {
        tasks.filter { $0.isProject && $0.status != .trashed && $0.areaID == areaID }
            .sorted { $0.index < $1.index }
    }

    var openProjects: [TaskItem] {
        tasks.filter { $0.isProject && $0.isOpen }.sorted { $0.index < $1.index }
    }

    func children(of projectID: String) -> [TaskItem] {
        tasks.filter { $0.projectID == projectID && $0.status != .trashed }
            .sorted { $0.index < $1.index }
    }

    func headings(of projectID: String) -> [TaskItem] {
        children(of: projectID).filter(\.isHeading)
    }

    func projectProgress(_ projectID: String) -> (done: Int, total: Int) {
        let children = tasks.filter { $0.projectID == projectID && $0.type == .todo && $0.status != .trashed }
        return (children.filter(\.isCompleted).count, children.count)
    }

    func setTagColor(_ tag: String, _ color: TagColor) {
        tagColorMap[tag] = color
        try? db.run("INSERT INTO tag_meta (name, color) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET color=excluded.color", [tag, color.rawValue])
        notifyStoreChange()
    }

    func renameTag(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        batch("Rename Tag") {
            for task in tasks where task.tags.contains(old) {
                setTags(task.id, task.tags.map { $0 == old ? name : $0 })
            }
        }
        if let color = tagColorMap[old] { setTagColor(name, color) }
        tagColorMap[old] = nil
        try? db.run("DELETE FROM tag_meta WHERE name = ?", [old])
        if extraTags.remove(old) != nil { extraTags.insert(name) }
        notifyStoreChange()
    }

    func deleteTag(_ tag: String) {
        batch("Delete Tag") {
            for task in tasks where task.tags.contains(tag) { setTags(task.id, task.tags.filter { $0 != tag }) }
        }
        tagColorMap[tag] = nil
        extraTags.remove(tag)
        try? db.run("DELETE FROM tag_meta WHERE name = ?", [tag])
        notifyStoreChange()
    }

    func addTagName(_ tag: String) {
        let name = tag.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        extraTags.insert(name)
        try? db.run("INSERT OR IGNORE INTO tag_meta (name, color) VALUES (?, ?)", [name, TagColor.defaultColor(for: name).rawValue])
        notifyStoreChange()
    }

    /// Every known tag: in use, coloured, or created in the Tags window.
    var knownTags: [String] {
        Array(Set(allTags).union(tagColorMap.keys).union(extraTags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var allTags: [String] {
        Array(Set(tasks.filter { $0.status != .trashed }.flatMap(\.tags))).sorted()
    }

    /// Open to-dos in a list. Completed items are excluded; `recentlyCompleted(in:)`
    /// returns the ones finished today so the UI can show them struck through.
    func tasks(in selection: Selection) -> [TaskItem] {
        let endOfToday = Date().startOfDay.addingDays(1)
        let now = Date()

        switch selection {
        case .builtin(let list):
            switch list {
            case .inbox:
                return tasks.filter {
                    $0.isOpen && $0.type == .todo && $0.projectID == nil &&
                    $0.bucket == .inbox && $0.startDate == nil
                }.sorted { $0.index < $1.index }

            case .today:
                let open = tasks.filter { $0.isOpen && $0.type == .todo && $0.isDueToday }
                let planned = plannedToday
                return open.sorted { first, second in
                    if first.isEvening != second.isEvening { return !first.isEvening }
                    // What Plan My Day put at the top stays there, in the planned order.
                    let firstPlanned = planned.contains(first.id), secondPlanned = planned.contains(second.id)
                    if firstPlanned != secondPlanned { return firstPlanned }
                    if firstPlanned { return first.index < second.index }
                    let firstOverdue = (first.deadline ?? .distantFuture) < now.startOfDay
                    let secondOverdue = (second.deadline ?? .distantFuture) < now.startOfDay
                    if firstOverdue != secondOverdue { return firstOverdue }
                    return first.index < second.index
                }

            case .upcoming:
                return tasks.filter {
                    guard $0.isOpen && $0.type == .todo else { return false }
                    if $0.bucket == .scheduled, let start = $0.startDate, start >= endOfToday { return true }
                    if $0.startDate == nil, let deadline = $0.deadline, deadline >= endOfToday { return true }
                    return false
                }.sorted {
                    (($0.startDate ?? $0.deadline) ?? .distantFuture, $0.index) <
                        (($1.startDate ?? $1.deadline) ?? .distantFuture, $1.index)
                }

            case .anytime:
                // Things: Anytime holds everything you could do now, including Today's to-dos.
                return tasks.filter {
                    $0.isOpen && $0.type == .todo && (($0.bucket == .anytime && $0.startDate == nil) || $0.isDueToday)
                }.sorted { $0.index < $1.index }

            case .someday:
                return tasks.filter { $0.isOpen && $0.type == .todo && $0.bucket == .someday }
                    .sorted { $0.index < $1.index }

            case .logbook:
                return tasks.filter { ($0.type == .todo || $0.isProject) && $0.isCompleted }
                    .sorted { ($0.completedAt ?? $0.modifiedAt) > ($1.completedAt ?? $1.modifiedAt) }

            case .trash:
                return tasks.filter { $0.status == .trashed }
                    .sorted { $0.modifiedAt > $1.modifiedAt }

            case .ideas:
                return ideas

            case .active:
                return tasks.filter { $0.isOpen && $0.type == .todo && ($0.stage == .progress || $0.stage == .waiting) }
                    .sorted { ($0.stage == .progress ? 0 : 1, $0.index) < ($1.stage == .progress ? 0 : 1, $1.index) }
            }

        case .project(let id):
            return children(of: id).filter { $0.isOpen }

        case .area(let id):
            return tasks.filter {
                $0.isOpen && $0.type == .todo && $0.areaID == id && $0.projectID == nil
            }.sorted { $0.index < $1.index }

        case .tag(let tag):
            return tasks.filter { $0.isOpen && $0.type == .todo && $0.tags.contains(tag) }
                .sorted { $0.index < $1.index }
        }
    }

    /// To-dos completed or canceled today that belong to this list. Things keeps
    /// them visible until the day rolls over.
    func recentlyCompleted(in selection: Selection) -> [TaskItem] {
        let cutoff = Preferences.logImmediately ? Date().addingTimeInterval(-2.5) : Date().startOfDay
        let done = tasks.filter { $0.isCompleted && $0.type == .todo && ($0.completedAt.map { $0 >= cutoff } ?? false) }
        switch selection {
        case .builtin(.today): return done.filter(\.isDueToday).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        case .project(let id): return done.filter { $0.projectID == id }.sorted { $0.index < $1.index }
        case .area(let id): return done.filter { $0.areaID == id && $0.projectID == nil }.sorted { $0.index < $1.index }
        case .builtin(.inbox): return done.filter { $0.bucket == .inbox && $0.projectID == nil }
        case .builtin(.anytime): return done.filter { $0.bucket == .anytime && $0.startDate == nil }
        case .builtin(.active): return done.filter { $0.stage == .progress || $0.stage == .waiting }
        default: return []
        }
    }

    func count(for list: BuiltinList) -> Int {
        tasks(in: .builtin(list)).count
    }

    var todayBadgeCount: Int {
        tasks(in: .builtin(.today)).count
    }

    func upcomingGroups() -> [(date: Date, tasks: [TaskItem])] {
        let items = tasks(in: .builtin(.upcoming))
        let grouped = Dictionary(grouping: items) { ($0.startDate ?? $0.deadline ?? Date()).startOfDay }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.index < $1.index }) }
    }

    /// Quick Find: every non-trashed item whose title, notes, tags or checklist match.
    func search(_ query: String) -> [TaskItem] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return tasks.filter { item in
            guard item.status != .trashed, !item.isHeading else { return false }
            if item.title.lowercased().contains(needle) { return true }
            if item.notes.lowercased().contains(needle) { return true }
            if item.tags.contains(where: { $0.lowercased().contains(needle) }) { return true }
            if item.checklist.contains(where: { $0.title.lowercased().contains(needle) }) { return true }
            return false
        }.sorted { first, second in
            if first.isOpen != second.isOpen { return first.isOpen }
            if first.isProject != second.isProject { return first.isProject }
            return first.modifiedAt > second.modifiedAt
        }
    }

    /// The sidebar list a to-do currently lives in, for "Show in list".
    func homeSelection(for task: TaskItem) -> Selection {
        if task.isIdea && task.isOpen { return .builtin(.ideas) }
        if let projectID = task.projectID, self.task(projectID) != nil { return .project(projectID) }
        if let areaID = task.areaID, area(areaID) != nil { return .area(areaID) }
        if task.status == .trashed { return .builtin(.trash) }
        if task.isCompleted { return .builtin(.logbook) }
        if task.isDueToday { return .builtin(.today) }
        if task.bucket == .scheduled { return .builtin(.upcoming) }
        if task.bucket == .someday { return .builtin(.someday) }
        if task.bucket == .anytime { return .builtin(.anytime) }
        return .builtin(.inbox)
    }

    // MARK: - Seed

    private func seed() {
        suppressNotifications = true
        let area = createArea(title: "Personal")

        let project = createProject(title: "Welcome to Things 4", notes: "A quick tour. Delete this project when you are done.", areaID: area.id)
        let basics = createHeading(title: "Basics", projectID: project.id)
        let steps = [
            ("Press ⌘N to add a to-do", "Type a title, hit Return, and the row stays open for the next one."),
            ("Press Return on a to-do to open it", "Edit the title, notes, When, Deadline, tags, checklist and repeat schedule."),
            ("Drag to-dos to reorder them", "Drop them on a list, project or area in the sidebar to move them."),
            ("Press ⌃Space anywhere for Quick Entry", "Capture a thought from any app. It lands in your Inbox.")
        ]
        for (title, notes) in steps {
            createTask(title: title, notes: notes, bucket: .anytime, projectID: project.id, areaID: area.id, headingID: basics.id)
        }
        let more = createHeading(title: "Going further", projectID: project.id)
        createTask(title: "Open Settings with ⌘, to pick Light or Dark", notes: "Turn the AI features off there too if you never want them.",
                   bucket: .anytime, projectID: project.id, areaID: area.id, headingID: more.id)
        createTask(title: "Right-click a to-do for every action", notes: "When, Deadline, Move, Tags, Repeat, Complete, Cancel, Duplicate, Delete.",
                   bucket: .anytime, projectID: project.id, areaID: area.id, headingID: more.id)
        createTask(title: "Explore the Today list", bucket: .scheduled, startDate: Date().startOfDay, areaID: area.id)
        createTask(title: "Wind down", notes: "Evening to-dos sit in their own section.", bucket: .scheduled, startDate: Date().startOfDay, isEvening: true)
        createTask(title: "Write down the first thing on your mind", bucket: .inbox)
        undoManager.removeAllActions()
        suppressNotifications = false
    }
}
