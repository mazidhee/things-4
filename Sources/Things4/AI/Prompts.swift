import Foundation

struct TaskDraft {
    var title: String
    var notes: String = ""
    var when: String = "inbox"
    var deadline: String?
    var tags: [String] = []
    var checklist: [String] = []
    var project: String?
}

struct ProjectDraft {
    var title: String
    var notes: String = ""
    var tasks: [TaskDraft] = []
}

struct TriageSuggestion {
    var taskID: String
    var action: String
    var reason: String
}

struct SearchHit {
    var taskID: String
    var why: String
}

enum AIContext {
    static func selectionTitle() -> String {
        switch AppState.shared.selection {
        case .builtin(let list): return list.title
        case .project(let id): return TaskStore.shared.task(id)?.title ?? "Project"
        case .area(let id): return TaskStore.shared.area(id)?.title ?? "Area"
        case .tag(let tag): return "#" + tag
        }
    }

    static func compactTasks(limit: Int = 80) -> String {
        let tasks = TaskStore.shared.tasks(in: AppState.shared.selection).filter(\.isOpen).prefix(limit)
        if tasks.isEmpty { return "(no open to-dos in this list)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return tasks.map { task in
            var parts = ["[\(task.id)] \(task.title)"]
            if let start = task.startDate { parts.append("start \(formatter.string(from: start))") }
            if let deadline = task.deadline { parts.append("due \(formatter.string(from: deadline))") }
            if let projectID = task.projectID, let project = TaskStore.shared.task(projectID) {
                parts.append("project: \(project.title)")
            }
            if !task.tags.isEmpty { parts.append("tags: " + task.tags.joined(separator: ",")) }
            if !task.notes.isEmpty {
                let notes = task.notes.replacingOccurrences(of: "\n", with: " ")
                parts.append("notes: " + String(notes.prefix(160)))
            }
            return "- " + parts.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    static func todayDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        return formatter.string(from: Date())
    }

    static func projectNames() -> String {
        let names = TaskStore.shared.tasks.filter { $0.isProject && $0.status != .trashed }.map(\.title)
        return names.isEmpty ? "(none)" : names.joined(separator: ", ")
    }
}

enum Prompts {
    static func chatSystem() -> String {
        """
        You are the assistant inside Things 4, a personal task manager for macOS. \
        Today is \(AIContext.todayDate()). The user is looking at the list "\(AIContext.selectionTitle())".

        Open to-dos in that list:
        \(AIContext.compactTasks())

        Existing projects: \(AIContext.projectNames())

        Answer in short, direct prose. Use the user's real task titles when you refer to them. \
        If you propose new to-dos, put them at the very end in a fenced code block tagged things4-actions:

        ```things4-actions
        {"tasks":[{"title":"...","notes":"...","when":"today|tomorrow|anytime|someday|inbox|YYYY-MM-DD","tags":["..."],"checklist":["..."]}]}
        ```

        Do not invent task IDs. Do not claim you changed anything: the app shows an Apply button and the user decides.
        """
    }

    static func captureSystem() -> String {
        """
        You turn a sentence into one to-do for Things 4. Today is \(AIContext.todayDate()).
        Projects that already exist: \(AIContext.projectNames()).

        Return ONLY a JSON object, no prose and no markdown fences:
        {"title":"short imperative title","notes":"optional detail","when":"inbox|anytime|someday|today|tomorrow|YYYY-MM-DD","deadline":"YYYY-MM-DD or null","tags":["tag"],"checklist":["step"],"project":"existing project name or null"}

        Keep the title under 90 characters. Use "inbox" when no timing is implied. \
        Only fill checklist when the user listed real steps. Never invent a deadline.
        """
    }

    static func planSystem() -> String {
        """
        You turn an outcome into a small project for Things 4. Today is \(AIContext.todayDate()).
        Existing projects: \(AIContext.projectNames()).

        Return ONLY a JSON object, no prose and no markdown fences:
        {"title":"project title","notes":"one or two sentences of scope","tasks":[{"title":"...","notes":"...","when":"inbox|anytime|someday|today|tomorrow|YYYY-MM-DD","tags":["..."],"checklist":["..."]}]}

        Write 4 to 12 tasks. Order them so each one unblocks the next. Start with the first physical action. \
        Do not add a task called "plan" or "review" unless it is genuinely actionable.
        """
    }

    static func triageSystem() -> String {
        """
        You triage a Today list. Be honest and brief. Today is \(AIContext.todayDate()).

        To-dos:
        \(AIContext.compactTasks())

        Return ONLY a JSON object, no prose and no markdown fences:
        {"items":[{"id":"exact task id","action":"keep|defer|someday|complete","reason":"max 12 words"}]}

        Rank by deadline pressure, how long the task has been open, and whether other work depends on it. \
        Use "defer" for something that can wait, "someday" for something with no current commitment, \
        and "keep" for the few things that genuinely belong today. Include every task exactly once. \
        Never invent ids.
        """
    }

    static func searchSystem() -> String {
        """
        You search a personal task list by meaning, not just keywords. Today is \(AIContext.todayDate()).

        Candidate to-dos:
        \(AIContext.compactTasks(limit: 200))

        Return ONLY a JSON object, no prose and no markdown fences:
        {"matches":[{"id":"exact task id","why":"max 14 words"}]}

        Return at most 8 matches, best first. If nothing matches, return {"matches":[]}. Never invent ids.
        """
    }

    static func enhanceSystem() -> String {
        """
        You rewrite one to-do for Things 4. Today is \(AIContext.todayDate()).
        Keep the user's meaning and any concrete facts. Do not add commitments they did not make.

        Return ONLY a JSON object, no prose and no markdown fences:
        {"title":"clearer title under 90 characters","notes":"short useful detail, or empty string"}
        """
    }
}

enum AIJSON {
    static func object(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let candidate = String(text[start...end])
        if let data = candidate.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return value
        }
        return nil
    }

    static func tasks(from object: [String: Any]) -> [TaskDraft] {
        let raw = (object["tasks"] as? [[String: Any]]) ?? (object["items"] as? [[String: Any]]) ?? []
        return raw.compactMap { taskDraft(from: $0) }
    }

    static func taskDraft(from object: [String: Any]) -> TaskDraft? {
        guard let title = object["title"] as? String, !title.isEmpty else { return nil }
        return TaskDraft(
            title: title,
            notes: object["notes"] as? String ?? "",
            when: (object["when"] as? String) ?? "inbox",
            deadline: object["deadline"] as? String,
            tags: (object["tags"] as? [String]) ?? [],
            checklist: (object["checklist"] as? [String]) ?? [],
            project: object["project"] as? String
        )
    }

    static func projectDraft(from text: String) -> ProjectDraft? {
        guard let object = object(from: text),
              let title = object["title"] as? String else { return nil }
        let tasks = AIJSON.tasks(from: object)
        return ProjectDraft(title: title,
                            notes: object["notes"] as? String ?? "",
                            tasks: tasks)
    }

    static func triage(from text: String) -> [TriageSuggestion] {
        guard let object = object(from: text), let items = object["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return TriageSuggestion(taskID: id,
                                    action: item["action"] as? String ?? "keep",
                                    reason: item["reason"] as? String ?? "")
        }
    }

    static func searchHits(from text: String) -> [SearchHit] {
        guard let object = object(from: text), let items = object["matches"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return SearchHit(taskID: id, why: item["why"] as? String ?? "")
        }
    }

    static func polish(from text: String) -> (title: String, notes: String)? {
        guard let object = object(from: text), let title = object["title"] as? String else { return nil }
        return (title, object["notes"] as? String ?? "")
    }

    static func apply(_ draft: TaskDraft, defaultProjectID: String? = nil, defaultAreaID: String? = nil) -> TaskItem {
        let store = TaskStore.shared
        var projectID = defaultProjectID
        var areaID = defaultAreaID

        if let name = draft.project, !name.isEmpty {
            if let existing = store.tasks.first(where: { $0.isProject && $0.title.lowercased() == name.lowercased() }) {
                projectID = existing.id
                areaID = existing.areaID
            }
        }

        let bucket: StartBucket
        var start: Date?
        switch draft.when.lowercased() {
        case "today":
            bucket = .scheduled
            start = Date().startOfDay
        case "tomorrow":
            bucket = .scheduled
            start = Date().startOfDay.addingDays(1)
        case "anytime":
            bucket = .anytime
        case "someday":
            bucket = .someday
        case "inbox", "":
            bucket = projectID == nil ? .inbox : .anytime
        default:
            if let date = Date.fromISO(draft.when) {
                bucket = .scheduled
                start = date.startOfDay
            } else {
                bucket = .inbox
            }
        }

        return store.createTask(title: draft.title,
                                notes: draft.notes,
                                bucket: bucket,
                                startDate: start,
                                deadline: Date.fromISO(draft.deadline),
                                projectID: projectID,
                                areaID: areaID,
                                tags: draft.tags,
                                checklist: draft.checklist)
    }
}
