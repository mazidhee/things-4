import AppKit

/// The automation layer other apps and AI agents use to talk to Things 4. Three
/// front doors share these commands:
///  • the URL scheme `things4:///add?title=…`, with Things 3's commands and parameter names
///  • a local HTTP API on 127.0.0.1 (APIServer), JSON in and out, bearer token in api.json
///  • `Things4 --mcp`, an MCP server for agents, and `Things4 --cli` (AgentBridge)
/// Parameter names are Things 3's kebab-case ("checklist-items"); snake_case works too.
enum ThingsAPI {
    struct Failure: Error {
        let message: String
        var status = 400
        init(_ message: String, status: Int = 400) { self.message = message; self.status = status }
    }

    typealias Params = [String: Any]

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0" }

    // MARK: - Parameters

    /// "append_notes" and "appendNotes" both become "append-notes".
    static func normalize(_ params: Params) -> Params {
        var out: Params = [:]
        for (key, value) in params {
            var name = ""
            for character in key {
                if character == "_" { name.append("-") }
                else if character.isUppercase { name.append("-"); name.append(Character(character.lowercased())) }
                else { name.append(character) }
            }
            out[name] = value
        }
        for (alias, canonical) in ["checklist": "checklist-items", "todos": "to-dos", "items": "to-dos", "project": "list",
                                   "project-id": "list-id", "tag": "tags", "due": "deadline", "remind": "reminder",
                                   "append-checklist": "append-checklist-items", "prepend-checklist": "prepend-checklist-items"]
        where out[canonical] == nil && out[alias] != nil {
            out[canonical] = out[alias]
        }
        return out
    }

    static func string(_ params: Params, _ key: String) -> String? {
        switch params[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    static func bool(_ params: Params, _ key: String) -> Bool? {
        switch params[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return ["true", "yes", "1"].contains(value.lowercased()) ? true : (["false", "no", "0"].contains(value.lowercased()) ? false : nil)
        default: return nil
        }
    }

    /// An array, or a string split on newlines (or commas, for tags).
    static func strings(_ params: Params, _ key: String, commas: Bool = false) -> [String]? {
        let raw: [String]
        switch params[key] {
        case let value as [Any]: raw = value.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["title"] as? String) }
        case let value as String: raw = value.components(separatedBy: commas ? CharacterSet(charactersIn: ",\n") : .newlines)
        default: return nil
        }
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Dates

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func day(_ date: Date?) -> String? { date.map { dayFormatter().string(from: $0) } }
    static func timestamp(_ date: Date?) -> String? {
        date.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withInternetDateTime]) }
    }

    /// "2026-11-20@14:30" (Things 3), "2026-11-20 14:30", or full ISO 8601.
    static func dateTime(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'@'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        if let at = text.firstIndex(of: "@"), let time = WhenPicker.parseTime(String(text[text.index(after: at)...])) {
            let dayPart = String(text[..<at])
            let base: Date?
            switch WhenPicker.parse(dayPart) {
            case .date(let d)?: base = d
            case .today?, .evening?: base = Date().startOfDay
            default: base = dayFormatter().date(from: dayPart)
            }
            if let base { return TaskStore.combine(day: base, timeOf: time) }
        }
        return nil
    }

    static func when(_ raw: String) throws -> WhenPicker.Choice {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let at = dateTime(text) { return .reminder(at) }
        if let day = dayFormatter().date(from: text) { return .date(day) }
        if let choice = WhenPicker.parse(text) { return choice }
        throw Failure("Couldn't understand when “\(raw)”. Use today, tomorrow, evening, anytime, someday, a date (2026-11-20, friday, in 3 days) or a date and time (tomorrow 9am, 2026-11-20@14:30).")
    }

    static func deadline(_ raw: String) throws -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        if let day = dayFormatter().date(from: text) { return day }
        if let at = dateTime(text) { return at.startOfDay }
        switch WhenPicker.parse(text, mode: .deadline) {
        case .date(let d)?: return d
        case .today?, .evening?: return Date().startOfDay
        default: throw Failure("Couldn't understand deadline “\(raw)”. Use a date like 2026-11-20, friday or in 2 weeks.")
        }
    }

    static func reminder(_ raw: String) throws -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        if let at = dateTime(text) ?? RemindPicker.parse(text) { return at }
        throw Failure("Couldn't understand reminder “\(raw)”. Use a time like 3pm, tomorrow 9am, in 20 min or 2026-11-20@14:30.")
    }

    // MARK: - Lookups

    private static var store: TaskStore { TaskStore.shared }

    /// A project or area, by id or (case-insensitive) title.
    /// With `create`, a missing name becomes a new project (inside `area`, made if needed).
    static func container(id: String?, name: String?, create: Bool = false, area: String? = nil) throws -> (projectID: String?, areaID: String?)? {
        if let id, !id.isEmpty {
            if let project = store.task(id), project.isProject { return (project.id, project.areaID) }
            if let area = store.area(id) { return (nil, area.id) }
            throw Failure("No project or area has the id \(id).", status: 404)
        }
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if let builtin = BuiltinList(rawValue: name.lowercased()), builtin == .inbox { return nil }
        if let project = store.tasks.first(where: { $0.isProject && $0.isOpen && $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return (project.id, project.areaID)
        }
        if let area = store.areas.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return (nil, area.id) }
        guard create else {
            throw Failure("No project or area is called “\(name)”. Create it with add-project, or leave list empty for the Inbox.", status: 404)
        }
        let areaID = try self.area(area, create: true)
        return (store.createProject(title: name, areaID: areaID).id, areaID)
    }

    /// An area by id or title; with `create`, a missing title becomes a new area.
    static func area(_ key: String?, create: Bool) throws -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { return nil }
        if let area = store.area(key) ?? store.areas.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }) { return area.id }
        if store.task(key)?.isProject == true { throw Failure("area must be an area, not a project.") }
        guard create else { throw Failure("No area is called “\(key)”.", status: 404) }
        return store.createArea(title: key).id
    }

    // MARK: - Source

    /// Who asked for a to-do: an agent's name ("tutor", "claude-code"), from the
    /// `source` parameter or the X-Things-Source header. It becomes a tag so you
    /// can filter one agent's work, plus an "Added by" line in the notes.
    static func source(_ params: Params) -> String? {
        guard let raw = string(params, "source")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != "none" else { return nil }
        return String(raw.prefix(40))
    }

    private static func addedBy(_ notes: String, _ source: String?) -> String {
        guard let source else { return notes }
        return notes + (notes.isEmpty ? "" : "\n\n") + "Added by \(source)"
    }

    private static func tagged(_ tags: [String], _ source: String?) -> [String] {
        guard let source, !tags.contains(where: { $0.caseInsensitiveCompare(source) == .orderedSame }) else { return tags }
        return tags + [source]
    }

    static func heading(id: String?, name: String?, projectID: String?, areaID: String?, create: Bool) -> String? {
        if let id, let heading = store.task(id), heading.isHeading { return heading.id }
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, projectID != nil || areaID != nil else { return nil }
        let headings = projectID.map { store.headings(of: $0) } ?? areaID.map { store.headings(inArea: $0) } ?? []
        if let heading = headings.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return heading.id }
        return create ? store.createHeading(title: name, projectID: projectID, areaID: projectID == nil ? areaID : nil).id : nil
    }

    static func item(_ id: String) throws -> TaskItem {
        guard let task = store.task(id) else { throw Failure("No to-do or project has the id \(id).", status: 404) }
        return task
    }

    // MARK: - Commands

    /// `add`: one or more to-dos. Returns what was created.
    static func add(_ raw: Params) throws -> [TaskItem] {
        let params = normalize(raw)
        let titles = strings(params, "titles") ?? string(params, "title").map { [$0] } ?? []
        guard !titles.isEmpty, titles.contains(where: { !$0.isEmpty }) else { throw Failure("A to-do needs a title.") }
        let when = try string(params, "when").flatMap { $0.isEmpty ? nil : try Self.when($0) }
        let deadline = try string(params, "deadline").flatMap { try Self.deadline($0) }
        let reminder = try string(params, "reminder").flatMap { try Self.reminder($0) }
        let source = Self.source(params)
        let tags = tagged(strings(params, "tags", commas: true) ?? [], source)
        let checklist = strings(params, "checklist-items") ?? []
        let notes = bool(params, "in-project") == true ? (string(params, "notes") ?? "") : addedBy(string(params, "notes") ?? "", source)
        let target = try container(id: string(params, "list-id"), name: string(params, "list"),
                                   create: bool(params, "create-list") != false, area: string(params, "area"))

        var created: [TaskItem] = []
        store.batch("Add To-Do") {
            let headingID = heading(id: string(params, "heading-id"), name: string(params, "heading"),
                                    projectID: target?.projectID, areaID: target?.areaID, create: true)
            for title in titles {
                let task = store.createTask(title: title, notes: notes, bucket: target == nil ? .inbox : .anytime,
                                            deadline: deadline, projectID: target?.projectID, areaID: target?.areaID,
                                            headingID: headingID, tags: tags, checklist: checklist)
                created.append(task)
            }
            let ids = created.map(\.id)
            for tag in tags { store.addTagName(tag) }
            when?.applyWhen(to: ids)
            if let reminder { for id in ids { store.setReminder(id, at: reminder) } }
            if bool(params, "completed") == true { ids.forEach(store.toggleCompletion) }
            else if bool(params, "canceled") == true { ids.forEach(store.cancel) }
        }
        if reminder != nil { ReminderService.shared.requestAuthorization() }
        return created.compactMap { store.task($0.id) }
    }

    /// `add-project`: a project, optionally with to-dos (strings or objects) and headings.
    static func addProject(_ raw: Params) throws -> [TaskItem] {
        let params = normalize(raw)
        guard let title = string(params, "title"), !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure("A project needs a title.")
        }
        let when = try string(params, "when").flatMap { $0.isEmpty ? nil : try Self.when($0) }
        let deadline = try string(params, "deadline").flatMap { try Self.deadline($0) }
        let source = Self.source(params)
        let tags = tagged(strings(params, "tags", commas: true) ?? [], source)
        let areaID = try area(string(params, "area-id") ?? string(params, "area"), create: true)

        var todoParams: [Params] = []
        switch params["to-dos"] {
        case let list as [Any]:
            for entry in list {
                if let text = entry as? String { todoParams.append(["title": text]) }
                else if let object = entry as? [String: Any] {
                    // Things 3 JSON nests {type, attributes}.
                    let attributes = (object["attributes"] as? [String: Any]) ?? object
                    var item = normalize(attributes)
                    if (object["type"] as? String) == "heading" { item["is-heading"] = true }
                    todoParams.append(item)
                }
            }
        case let text as String:
            todoParams = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { ["title": $0] }
        default: break
        }

        var made: [String] = []
        var failure: Failure?
        store.batch("New Project") {
            let project = store.createProject(title: title, notes: addedBy(string(params, "notes") ?? "", source), areaID: areaID)
            made.append(project.id)
            if !tags.isEmpty { store.setTags(project.id, tags); tags.forEach(store.addTagName) }
            when?.applyWhen(to: [project.id])
            if let deadline { store.setDeadline(project.id, date: deadline) }
            var currentHeading: String?
            for var item in todoParams {
                if bool(item, "is-heading") == true {
                    currentHeading = string(item, "title").map { store.createHeading(title: $0, projectID: project.id).id }
                    continue
                }
                item["list-id"] = project.id
                item["in-project"] = true
                if let source { item["source"] = source }
                if item["heading"] == nil, item["heading-id"] == nil, let currentHeading { item["heading-id"] = currentHeading }
                do { made += try add(item).map(\.id) } catch let error as Failure { failure = error } catch {}
            }
            if bool(params, "completed") == true { store.toggleCompletion(project.id) }
        }
        if let failure { throw failure }
        return made.compactMap { store.task($0) }
    }

    /// `update`: change an existing to-do or project. Empty values clear (when, deadline, reminder).
    static func update(_ raw: Params) throws -> TaskItem {
        let params = normalize(raw)
        guard let id = string(params, "id") else { throw Failure("update needs the id of a to-do or project.") }
        let task = try item(id)
        let when = try string(params, "when").map { $0.isEmpty ? WhenPicker.Choice.anytime : try Self.when($0) }
        let deadline = try string(params, "deadline").map { try Self.deadline($0) }
        let reminder = try string(params, "reminder").map { try Self.reminder($0) }
        let target = try (params["list-id"] != nil || params["list"] != nil)
            ? container(id: string(params, "list-id"), name: string(params, "list"), create: true, area: string(params, "area")) : nil
        let moveToInbox = string(params, "list")?.lowercased() == "inbox"

        store.batch("Update") {
            if let title = string(params, "title"), !title.isEmpty {
                task.isProject ? store.renameProject(id, to: title) : store.setTitle(id, title)
            }
            var notes = string(params, "notes") ?? task.notes
            if let prepend = string(params, "prepend-notes") { notes = prepend + (notes.isEmpty ? "" : "\n") + notes }
            if let append = string(params, "append-notes") { notes += (notes.isEmpty ? "" : "\n") + append }
            if notes != task.notes { store.setNotes(id, notes) }

            if let tags = strings(params, "tags", commas: true) { store.setTags(id, tags); tags.forEach(store.addTagName) }
            if let more = strings(params, "add-tags", commas: true) {
                let current = store.task(id)?.tags ?? []
                store.setTags(id, current + more.filter { !current.contains($0) })
                more.forEach(store.addTagName)
            }
            if let items = strings(params, "checklist-items") {
                for item in store.task(id)?.checklist ?? [] { store.deleteChecklistItem(id, itemID: item.id) }
                items.forEach { store.addChecklistItem(id, title: $0) }
            }
            if let items = strings(params, "prepend-checklist-items") {
                for item in items.reversed() {
                    store.addChecklistItem(id, title: item)
                    if let count = store.task(id)?.checklist.count { store.moveChecklistItem(id, from: count - 1, to: 0) }
                }
            }
            strings(params, "append-checklist-items")?.forEach { store.addChecklistItem(id, title: $0) }

            if let target {
                store.move(id, toProject: target.projectID, areaID: target.areaID)
                if store.task(id)?.bucket == .inbox { store.setBucket(id, bucket: .anytime) }
            } else if moveToInbox {
                store.move(id, toProject: nil, areaID: nil)
                store.setBucket(id, bucket: .inbox)
            }
            if params["heading"] != nil || params["heading-id"] != nil, let current = store.task(id) {
                let headingID = heading(id: string(params, "heading-id"), name: string(params, "heading"),
                                        projectID: current.projectID, areaID: current.areaID, create: true)
                store.setHeading(id, headingID: headingID)
            }

            when?.applyWhen(to: [id])
            if let deadline { store.setDeadline(id, date: deadline) }
            if let reminder { store.setReminder(id, at: reminder) }

            let current = store.task(id) ?? task
            if let completed = bool(params, "completed") {
                if completed && current.isOpen { store.toggleCompletion(id) }
                if !completed && current.isCompleted { store.reopen(id) }
            }
            if bool(params, "canceled") == true, store.task(id)?.isOpen == true { store.cancel(id) }
        }
        if reminder != nil { ReminderService.shared.requestAuthorization() }
        return try item(id)
    }

    /// Things 3's `json` command: an array of {type: "to-do" | "project", operation?, id?, attributes}.
    static func json(_ data: Any, source: String? = nil) throws -> [TaskItem] {
        let entries: [Any]
        if let text = data as? String {
            guard let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { throw Failure("data is not valid JSON.") }
            entries = (decoded as? [Any]) ?? [decoded]
        } else {
            entries = (data as? [Any]) ?? [data]
        }
        var results: [TaskItem] = []
        for case let entry as [String: Any] in entries {
            let type = (entry["type"] as? String ?? "to-do").lowercased()
            var attributes = (entry["attributes"] as? [String: Any]) ?? entry.filter { $0.key != "type" && $0.key != "operation" }
            if let source, attributes["source"] == nil, (entry["operation"] as? String) != "update" { attributes["source"] = source }
            if (entry["operation"] as? String) == "update" {
                attributes["id"] = entry["id"] ?? attributes["id"]
                results.append(try update(attributes))
            } else if type == "project" {
                results += try addProject(attributes)
            } else {
                if let items = attributes["checklist-items"] as? [Any] {
                    attributes["checklist-items"] = items.compactMap { ($0 as? String) ?? ((($0 as? [String: Any])?["attributes"] as? [String: Any])?["title"] as? String) }
                }
                results += try add(attributes)
            }
        }
        return results
    }

    /// `add-area`: returns the area, reusing one with the same title.
    static func addArea(_ raw: Params) throws -> [String: Any] {
        let params = normalize(raw)
        guard let title = string(params, "title")?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            throw Failure("An area needs a title.")
        }
        if store.task(title)?.isProject == true || store.tasks.contains(where: { $0.isProject && $0.isOpen && $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            throw Failure("A project is already called “\(title)”. Pick another name for the area.")
        }
        guard let id = try area(title, create: true) else { throw Failure("An area needs a title.") }
        return areas().first { ($0["id"] as? String) == id } ?? ["id": id, "title": title]
    }

    static func complete(_ id: String) throws -> TaskItem {
        let task = try item(id)
        if task.isOpen { store.toggleCompletion(id) }
        return try item(id)
    }

    static func trash(_ id: String) throws -> TaskItem {
        _ = try item(id)
        store.moveToTrash(id)
        return try item(id)
    }

    // MARK: - Reading

    /// A built-in list (today, inbox…), or a project, area or tag by id or name.
    static func list(_ name: String) throws -> [TaskItem] {
        if let builtin = BuiltinList(rawValue: name.lowercased()) { return store.tasks(in: .builtin(builtin)) }
        if name.lowercased() == "evening" { return store.tasks(in: .builtin(.today)).filter(\.isEvening) }
        let isID = store.task(name) != nil || store.area(name) != nil
        if let target = try? container(id: isID ? name : nil, name: isID ? nil : name) {
            return target.projectID.map { store.tasks(in: .project($0)) } ?? target.areaID.map { store.tasks(in: .area($0)) } ?? []
        }
        if let tag = store.allTags.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return store.tasks(in: .tag(tag)) }
        throw Failure("No list called “\(name)”. Use today, evening, inbox, upcoming, anytime, someday, logbook, or a project, area or tag.", status: 404)
    }

    /// Filters for GET /v1/tasks: q, status (open | completed | canceled | all), tag, completed-since, modified-since.
    static func query(_ raw: Params) throws -> [TaskItem] {
        let params = normalize(raw)
        var items: [TaskItem]
        if let q = string(params, "q") ?? string(params, "query"), !q.isEmpty { items = store.search(q) }
        else if let list = string(params, "list") { items = try Self.list(list) }
        else { items = store.tasks.filter { !$0.isHeading && $0.status != .trashed } }
        let status = string(params, "status")?.lowercased() ?? (params["completed-since"] != nil ? "completed" : "open")
        switch status {
        case "open": items = items.filter(\.isOpen)
        case "completed": items = items.filter { $0.status == .completed }
        case "canceled": items = items.filter(\.isCanceled)
        case "all": break
        default: throw Failure("status must be open, completed, canceled or all.")
        }
        if let tag = string(params, "tags") { items = items.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } } }
        if let since = string(params, "completed-since") {
            guard let date = dateTime(since) ?? dayFormatter().date(from: since) else { throw Failure("completed-since must be an ISO date or date-time.") }
            items = items.filter { ($0.completedAt ?? .distantPast) >= date }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
        if let since = string(params, "modified-since") {
            guard let date = dateTime(since) ?? dayFormatter().date(from: since) else { throw Failure("modified-since must be an ISO date or date-time.") }
            items = items.filter { $0.modifiedAt >= date }
        }
        if let limit = string(params, "limit").flatMap(Int.init) { items = Array(items.prefix(limit)) }
        return items
    }

    /// Where a to-do shows, in Things' words.
    static func whenLabel(_ task: TaskItem) -> String {
        if task.status == .trashed { return "trash" }
        if task.isCompleted { return "logbook" }
        if task.isDueToday && task.isTodo { return task.isEvening ? "evening" : "today" }
        switch task.bucket {
        case .inbox: return "inbox"
        case .anytime: return "anytime"
        case .someday: return "someday"
        case .scheduled: return "upcoming"
        }
    }

    static func encode(_ task: TaskItem) -> [String: Any] {
        var out: [String: Any] = [
            "id": task.id,
            "type": task.isProject ? "project" : (task.isHeading ? "heading" : "to-do"),
            "title": task.title,
            "notes": task.notes,
            "status": task.status.rawValue,
            "list": whenLabel(task),
            "tags": task.tags,
            "checklist": task.checklist.sorted { $0.index < $1.index }.map { ["id": $0.id, "title": $0.title, "completed": $0.done] },
            "created": timestamp(task.createdAt) ?? "",
            "modified": timestamp(task.modifiedAt) ?? "",
            "url": "things4:///show?id=\(task.id)"
        ]
        if let start = task.startDate { out["start-date"] = day(start) }
        if let deadline = task.deadline { out["deadline"] = day(deadline) }
        if let reminder = task.reminder { out["reminder"] = timestamp(reminder) }
        if let completed = task.completedAt, task.isCompleted { out["completed-at"] = timestamp(completed) }
        if let repeatRule = task.repeatRule { out["repeat"] = repeatRule.summary }
        if let projectID = task.projectID, let project = store.task(projectID) { out["project"] = ["id": project.id, "title": project.title] }
        if let areaID = task.areaID, let area = store.area(areaID) { out["area"] = ["id": area.id, "title": area.title] }
        if let headingID = task.headingID, let heading = store.task(headingID) { out["heading"] = ["id": heading.id, "title": heading.title] }
        if task.isProject {
            let progress = store.projectProgress(task.id)
            out["progress"] = ["done": progress.done, "total": progress.total]
        }
        return out
    }

    static func projects() -> [[String: Any]] { store.openProjects.map(encode) }

    static func areas() -> [[String: Any]] {
        store.areas.sorted { $0.index < $1.index }.map { area in
            ["id": area.id, "title": area.title, "projects": store.projects(inArea: area.id).filter(\.isOpen).map { ["id": $0.id, "title": $0.title] }]
        }
    }

    static func tags() -> [String] { store.allTags }

    // MARK: - Showing

    /// Brings Things 4 forward on a list ("today", a project or area id/name) or a to-do.
    static func show(id: String?, query: String?) throws {
        let controller = MainWindowController.active ?? .shared
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let key = (id ?? query ?? "").trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return }
        if let builtin = BuiltinList(rawValue: key.lowercased()) { AppState.shared.selection = .builtin(builtin); return }
        if let area = store.area(key) ?? store.areas.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }) {
            AppState.shared.selection = .area(area.id); return
        }
        let task = store.task(key) ?? store.search(key).first
        guard let task else { throw Failure("Nothing called “\(key)”.", status: 404) }
        if task.isProject { AppState.shared.selection = .project(task.id); return }
        NotificationCenter.default.post(name: .openTask, object: task.id, userInfo: ["edit": true])
    }
}
