import Foundation

/// One line of a day plan: an existing to-do to pull into today, or a new one to create.
struct PlanItem: Equatable {
    enum When: String {
        case today, evening, tomorrow, later

        var title: String {
            switch self {
            case .today: return "Today"
            case .evening: return "This Evening"
            case .tomorrow: return "Tomorrow"
            case .later: return "Later"
            }
        }
    }

    var taskID: String?
    var title: String
    var priority: Priority = .none
    var when: When = .today
    var projectID: String?
    var estimate: Int = 0
    var waitingOn: String?
    var include = true
}

/// Turns a spoken or typed ramble ("I need to get X, Y and Z done today, X is the big one")
/// into an ordered list for Today. With AI switched on the model reads it; otherwise a
/// rule-based reader on this Mac does, so the feature always works offline.
enum DayPlanner {
    private static var store: TaskStore { .shared }

    // MARK: - Entry points

    struct Result {
        var items: [PlanItem]
        var usedAI: Bool
        var problem: String?
    }

    static var aiUsable: Bool {
        guard Preferences.aiEnabled else { return false }
        let provider = AISettings.provider
        return AISettings.hasKey(for: provider) || AIClient.isLocal(AISettings.baseURL(for: provider))
    }

    @MainActor
    static func plan(_ text: String) async -> Result {
        var problem: String?
        if aiUsable {
            do {
                let reply = try await AIClient.complete(system: systemPrompt(), messages: [AIMessage(role: "user", content: text)], maxTokens: 1800)
                if let object = AIJSON.object(from: reply) {
                    let items = parse(object)
                    if !items.isEmpty { return Result(items: ordered(items), usedAI: true, problem: nil) }
                }
                problem = "The model's answer could not be read, so this was sorted on your Mac."
            } catch {
                problem = error.localizedDescription + " Sorted on your Mac instead."
            }
        }
        return Result(items: offline(text), usedAI: false, problem: problem)
    }

    /// Highest priority first; within a priority, the order they were said.
    static func ordered(_ items: [PlanItem]) -> [PlanItem] {
        items.enumerated().sorted { ($1.element.priority.rawValue, $0.offset) < ($0.element.priority.rawValue, $1.offset) }.map(\.element)
    }

    // MARK: - Applying

    /// Schedules the plan and puts Today in the planned order. One undo step.
    @discardableResult
    static func apply(_ items: [PlanItem], clearRest: Bool = false) -> [String] {
        var ids: [String] = []
        var todayIDs: [String] = []
        let today = Date().startOfDay
        store.batch("Plan My Day") {
            let chosen = items.filter(\.include)
            if clearRest {
                let keep = Set(chosen.compactMap(\.taskID))
                for task in store.tasks(in: .builtin(.today)) where !keep.contains(task.id) {
                    // A to-do that is in Today because its deadline arrived stays there.
                    if let deadline = task.deadline, deadline < today.addingDays(1) { continue }
                    store.setBucket(task.id, bucket: .anytime)
                }
            }
            for item in chosen {
                var id = item.taskID.flatMap { store.task($0)?.id }
                if id == nil {
                    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    let project = item.projectID.flatMap { store.task($0) }
                    id = store.createTask(title: title, bucket: .anytime, projectID: project?.id, areaID: project?.areaID).id
                }
                guard let id else { continue }
                if store.task(id)?.isCompleted == true { store.reopen(id) }
                switch item.when {
                case .today:
                    if store.task(id)?.isEvening == true { store.setEvening(id, false) }
                    store.setBucket(id, bucket: .scheduled, date: today)
                    todayIDs.append(id)
                case .evening:
                    store.setBucket(id, bucket: .scheduled, date: today)
                    store.setEvening(id, true)
                    todayIDs.append(id)
                case .tomorrow:
                    store.setBucket(id, bucket: .scheduled, date: today.addingDays(1))
                case .later:
                    break
                }
                if item.priority != .none { store.setPriority(id, item.priority) }
                if item.estimate > 0 { store.setEstimate(id, minutes: item.estimate) }
                if let waitingOn = item.waitingOn, !waitingOn.isEmpty { store.setWaiting(id, on: waitingOn) }
                ids.append(id)
            }
            let rest = store.tasks(in: .builtin(.today)).map(\.id).filter { !todayIDs.contains($0) }
            store.reorder(todayIDs + rest)
            store.setPlannedToday(todayIDs)
        }
        return ids
    }

    // MARK: - Model

    static func systemPrompt() -> String {
        let open = store.tasks.filter { $0.isTodo && $0.isOpen }.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(160)
        let list = open.map { task -> String in
            let project = task.projectID.flatMap { store.task($0)?.title }.map { " [\($0)]" } ?? ""
            return "\(task.id) | \(task.title)\(project)"
        }.joined(separator: "\n")
        let projects = store.openProjects.map(\.title).joined(separator: ", ")
        return """
        The user is talking through what they want to get done. It is dictated speech: rambling, with filler and corrections. \
        Turn it into their plan for the day. Today is \(AIContext.todayDate()).

        Their open to-dos (id | title [project]):
        \(list.isEmpty ? "(none)" : list)

        Their projects: \(projects.isEmpty ? "(none)" : projects)

        Return ONLY a JSON object, no prose and no markdown fences:
        {"items":[{"id":"id of the open to-do they mean, or null for a new one","title":"short imperative title","priority":"urgent|high|medium|low|none","when":"today|evening|tomorrow|later","project":"exact project name or null","estimate_minutes":null,"waiting_on":null}]}

        Rules:
        - One item per distinct thing they want to do. Drop filler, and keep only the last version when they correct themselves.
        - When what they say clearly refers to an open to-do, use its id and keep its title. Otherwise id is null and you write the title.
        - Priority comes from how they talk: "must", "no matter what", "the main thing" is urgent; "need to", "important" is high; \
        plain mentions are medium; "if I have time", "maybe" is low.
        - when is today unless they say tonight or this evening (evening), tomorrow, or put it off (later).
        - Only set estimate_minutes or waiting_on when they say it. Never invent to-dos they did not mention.
        - Order the items the way they should be worked: most important first.
        """
    }

    static func parse(_ object: [String: Any]) -> [PlanItem] {
        let raw = (object["items"] as? [[String: Any]]) ?? (object["tasks"] as? [[String: Any]]) ?? []
        var used: Set<String> = []
        return raw.compactMap { entry in
            let existing = (entry["id"] as? String).flatMap { store.task($0) }.flatMap { $0.isTodo && $0.status != .trashed && !used.contains($0.id) ? $0 : nil }
            let title = existing?.title ?? (entry["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            if let existing { used.insert(existing.id) }
            var item = PlanItem(taskID: existing?.id, title: title)
            item.priority = (entry["priority"] as? String).flatMap(Priority.named) ?? .none
            item.when = (entry["when"] as? String).flatMap { PlanItem.When(rawValue: $0.lowercased()) } ?? .today
            if existing == nil, let name = entry["project"] as? String {
                item.projectID = store.openProjects.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }?.id
            }
            item.estimate = (entry["estimate_minutes"] as? Int) ?? (entry["estimate_minutes"] as? Double).map { Int($0) } ?? 0
            item.waitingOn = (entry["waiting_on"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return item
        }
    }

    // MARK: - Offline reader

    private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Splits speech into one clause per thought.
    static func clauses(_ text: String) -> [String] {
        var working = text.replacingOccurrences(of: "\n", with: ". ")
        working = replacing(working, #"\s*,?\s+(and then|and after that|after that|and also|oh,? and|oh and)\s+"#, with: ". ")
        working = replacing(working, #"\s*,?\s+(and|then|also|plus|but)\s+(?=(i|we|i'd|i'll|i've|maybe|if|finally|lastly|then|also|tonight|tomorrow|today|later|this evening|after work)\b)"#, with: ". ")
        return working.components(separatedBy: CharacterSet(charactersIn: ".!?;"))
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))) }
            .filter { !$0.isEmpty }
    }

    static func priority(in clause: String) -> Priority {
        let text = " " + clause.lowercased() + " "
        func has(_ cues: [String]) -> Bool { cues.contains { text.contains($0) } }
        if has(["if i have time", "if there's time", "if there is time", "maybe ", "would be nice", "at some point", "if possible", "eventually",
                "nice to have", "if i can", "not urgent", "can wait", "low priority", "no rush"]) { return .low }
        if has(["most important", "top priority", "number one", "really really", "really, really", " must ", "have to", "has to", "got to", "gotta",
                "critical", "urgent", "asap", "no matter what", "non-negotiable", "first thing", "absolutely", "before anything", "main thing", "biggest"]) { return .urgent }
        if has(["need to", "needs to", "important", "priority", "priorities", " really "]) { return .high }
        if has(["should", "want to", "would like", "i'd like", "like to", "going to", "gonna"]) { return .medium }
        return .none
    }

    static func when(in clause: String) -> PlanItem.When? {
        let text = clause.lowercased()
        if matches(text, #"\b(not today|later this week|next week|some other day|another day|some other time)\b"#) { return .later }
        if matches(text, #"\b(tonight|this evening|after work|after dinner)\b"#) { return .evening }
        if matches(text, #"\btomorrow\b"#) { return .tomorrow }
        return nil
    }

    static func estimate(in clause: String) -> Int {
        let text = clause.lowercased()
        if text.contains("half an hour") || text.contains("half hour") { return 30 }
        if matches(text, #"\b(a couple of|couple of|two) hours\b"#) { return 120 }
        if matches(text, #"\b(an|one) hour\b"#) { return 60 }
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?)\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange]) else { return 0 }
        return Int((text[unitRange].hasPrefix("h") ? value * 60 : value).rounded())
    }

    /// "Okay so I really need to get the staging package done today" → "The staging package".
    static func title(from clause: String) -> String {
        var text = clause
        var previous = ""
        while previous != text {
            previous = text
            text = replacing(text, #"^(okay|ok|so|um+|uh+|well|alright|right|and|then|also|first of all|firstly|first|secondly|second|thirdly|third|next|finally|lastly|oh|yeah|yes|today|tomorrow|tonight|now|basically|actually|honestly|i think|i guess|after that|the first thing is|first thing|another thing is|the other thing is|one more thing|if i have time|if there's time|if possible|maybe|probably|at some point)\b[,:\s]*"#, with: "")
            text = replacing(text, #"^(i|we)(\s+(really|also|still|just|definitely|absolutely|probably|kind of|kinda))*\s*('d|'ll|'ve| would| will| have| am|'m)?\s*(need|have|has|got|gotta|want|wanna|must|should|ought|like|love|going|gonna|plan|hope)\b(\s+to\b)?\s*"#, with: "")
            text = replacing(text, #"^(it would be (nice|good|great) to|it'd be (nice|good|great) to|let me|let's|make sure (to|that i|i)|try to|remember to|don't forget to|to)\b\s*"#, with: "")
        }
        text = replacing(text, #"^get\s+(.+?)\s+(done|finished|sorted out|sorted|out of the way|wrapped up|over with)\b.*$"#, with: "$1")
        text = replacing(text, #"\s*,?\s*\b(that's|that is|this is|it's|which is|because|since)\b.*$"#, with: "")
        text = replacing(text, #"\s*\(?\b(for\s+)?((about|around|roughly|maybe)\s+)?\d+(\.\d+)?\s*(hours?|hrs?|minutes?|mins?)\)?"#, with: "")
        text = replacing(text, #"\s*\b(for\s+)?((about|around|roughly|maybe)\s+)?(half an hour|an hour|one hour|a couple of hours|couple of hours|two hours)\b"#, with: "")
        previous = ""
        while previous != text {
            previous = text
            text = replacing(text, #"[,\s]+(today|tonight|this evening|tomorrow|by end of day|by the end of the day|by eod|first thing|this morning|this afternoon|as soon as possible|asap|if i have time|if possible|at some point|no matter what|for sure|as well|too|please|done|finished)\s*$"#, with: "")
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",:-")))
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }

    private static let stopwords: Set<String> = ["the", "a", "an", "to", "for", "of", "on", "in", "with", "and", "my", "that", "this", "up", "about",
                                                 "from", "into", "at", "it", "is", "be", "do", "get", "some", "our", "their", "his", "her", "me", "i"]

    static func tokens(_ text: String) -> Set<String> {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !stopwords.contains($0) }
        return Set(words.map { word -> String in
            for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) { return String(word.dropLast(suffix.count)) }
            return word
        })
    }

    /// The open to-do a phrase most plausibly refers to.
    static func match(_ phrase: String, among candidates: [TaskItem], excluding used: Set<String>) -> TaskItem? {
        let spoken = tokens(phrase)
        guard !spoken.isEmpty else { return nil }
        var best: (task: TaskItem, score: Double)?
        for task in candidates where !used.contains(task.id) {
            let own = tokens(task.title)
            guard !own.isEmpty else { continue }
            let shared = Double(own.intersection(spoken).count)
            guard shared > 0 else { continue }
            let coverage = shared / Double(own.count), said = shared / Double(spoken.count)
            let accepted = (shared >= 2 && (coverage >= 0.5 || said >= 0.6)) || (coverage == 1 && said >= 0.5) || (said == 1 && coverage >= 0.34)
            if accepted, coverage + said > (best?.score ?? 0) { best = (task, coverage + said) }
        }
        return best?.task
    }

    static func offline(_ text: String) -> [PlanItem] {
        let candidates = store.tasks.filter { $0.isTodo && $0.isOpen }
        let projects = store.openProjects
        var items: [PlanItem] = []
        var used: Set<String> = []

        func add(_ phrase: String, clause: String) {
            let spokenTitle = title(from: phrase)
            guard spokenTitle.count >= 2, spokenTitle.rangeOfCharacter(from: .letters) != nil else { return }
            var item = PlanItem(taskID: nil, title: spokenTitle, priority: priority(in: clause), when: when(in: clause) ?? .today)
            item.estimate = estimate(in: clause)
            if let existing = match(spokenTitle, among: candidates, excluding: used) {
                used.insert(existing.id)
                item.taskID = existing.id
                item.title = existing.title
            } else {
                let spoken = tokens(spokenTitle)
                item.projectID = projects.first { project in
                    let own = tokens(project.title)
                    return !own.isEmpty && own.isSubset(of: spoken) && spoken.count > own.count
                }?.id
            }
            items.append(item)
        }

        for clause in clauses(text) {
            // "That's the most important one", "these are my priorities": about what was just said.
            if matches(clause, #"^\s*(and\s+)?(that's|that is|that one|this is|these are|those are|it's|it is|they're|they are|which is|all of (that|those|these))\b"#) {
                let level = priority(in: clause)
                guard level != .none, !items.isEmpty else { continue }
                if matches(clause, #"^\s*(and\s+)?(these|those|they|all)\b"#) {
                    for index in items.indices where items[index].priority.rawValue < level.rawValue { items[index].priority = level }
                } else {
                    items[items.count - 1].priority = level
                }
                continue
            }
            // "X, Y and Z": a spoken list becomes one item each.
            let stripped = title(from: clause)
            let parts = replacing(stripped, #"\s*,\s*(and\s+)?|\s+and\s+"#, with: "|").components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let commaParts = stripped.components(separatedBy: ",").count
            let allKnown = parts.count > 1 && parts.allSatisfy { match($0, among: candidates, excluding: []) != nil }
            if parts.count > 1, (commaParts >= 2 && parts.count >= 3 && parts.allSatisfy { $0.split(separator: " ").count <= 8 }) || allKnown {
                for part in parts { add(part, clause: clause) }
            } else {
                add(clause, clause: clause)
            }
        }
        return ordered(items)
    }
}
