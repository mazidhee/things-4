import Foundation

/// `Things4 --mcp` (an MCP server on stdio, for AI agents) and `Things4 --cli`
/// (the `things4` command). Both are thin clients of the running app's HTTP API,
/// so the window updates live; they launch Things 4 in the background if needed.
enum AgentBridge {
    // MARK: - HTTP client

    struct Reply {
        var status: Int
        var json: Any?
        var text: String
    }

    /// The agent's name, tagged onto everything it creates. THINGS4_SOURCE wins (set it in the
    /// MCP config's "env", e.g. "tutor"); otherwise the client's own name from initialize.
    static var source: String? = ProcessInfo.processInfo.environment["THINGS4_SOURCE"]

    private static func config() -> (base: String, token: String)? {
        let object = APIConfig.read()
        guard let token = object["token"] as? String else { return nil }
        let port = ProcessInfo.processInfo.environment["THINGS4_API_PORT"].flatMap(Int.init) ?? (object["port"] as? Int) ?? Int(APIConfig.defaultPort)
        return ("http://127.0.0.1:\(port)/v1", token)
    }

    private static func send(_ method: String, _ path: String, body: Any? = nil, query: [String: String] = [:]) -> Reply? {
        guard let config = config(), var components = URLComponents(string: config.base + path) else { return nil }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let source, !source.isEmpty { request.setValue(source, forHTTPHeaderField: "X-Things-Source") }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var reply: Reply?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse {
                let data = data ?? Data()
                reply = Reply(status: response.statusCode,
                              json: try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                              text: String(data: data, encoding: .utf8) ?? "")
            }
            done.signal()
        }.resume()
        done.wait()
        return reply
    }

    /// Calls the API, launching Things 4 in the background first if it isn't running.
    static func call(_ method: String, _ path: String, body: Any? = nil, query: [String: String] = [:]) -> Reply {
        if let reply = send(method, path, body: body, query: query) { return reply }
        launchApp()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if let reply = send(method, path, body: body, query: query) { return reply }
        }
        return Reply(status: 503, json: ["error": "Things 4 isn't running and couldn't be opened, or its API is turned off in Settings › API."], text: "")
    }

    private static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let bundle = Bundle.main.bundleURL
        process.arguments = bundle.pathExtension == "app" ? ["-g", "-j", bundle.path] : ["-g", "-j", "-b", "com.tanay.things4"]
        try? process.run()
        process.waitUntilExit()
    }

    private static func pretty(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - MCP

    private static let todoFields: [String: Any] = [
        "title": ["type": "string", "description": "The to-do's title."],
        "notes": ["type": "string", "description": "Notes (Markdown: **bold**, [links](https://…), - lists)."],
        "when": ["type": "string", "description": "When to do it: today, evening, tomorrow, anytime, someday, a date (2026-11-20, friday, in 3 days). A time (tomorrow 9am, 2026-11-20@14:30) also sets a reminder."],
        "deadline": ["type": "string", "description": "Due date, e.g. 2026-11-20, friday, in 2 weeks."],
        "reminder": ["type": "string", "description": "Notify at this time on the Mac (and iPhone): 3pm, tomorrow 9am, in 20 min, 2026-11-20@14:30."],
        "tags": ["type": "array", "items": ["type": "string"], "description": "Tags, e.g. [\"learning\", \"rust\"]."],
        "checklist": ["type": "array", "items": ["type": "string"], "description": "Checklist steps inside the to-do."],
        "list": ["type": "string", "description": "Project or area title (or id) to put it in; a new project is created if none matches. Omit for the Inbox."],
        "area": ["type": "string", "description": "When list names a new project, the area to create it in (created too if missing)."],
        "heading": ["type": "string", "description": "Heading inside the project; created if missing."],
        "state": ["type": "string", "description": "Where it stands: backlog, todo, in-progress, waiting, done or canceled. in-progress also plans it for today."],
        "priority": ["type": "string", "description": "none, low, medium, high or urgent."],
        "estimate": ["type": "string", "description": "Expected effort: minutes (90) or hours (1.5h)."],
        "waiting_on": ["type": "string", "description": "Who or what it is waiting on, e.g. Henry. Sets the state to waiting."]
    ]

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static var tools: [[String: Any]] {
        var update = todoFields
        update["id"] = ["type": "string", "description": "The to-do or project id."]
        update["append_notes"] = ["type": "string", "description": "Text added to the end of the notes."]
        update["add_tags"] = ["type": "array", "items": ["type": "string"], "description": "Tags to add, keeping existing ones."]
        update["append_checklist"] = ["type": "array", "items": ["type": "string"], "description": "Checklist steps to add."]
        update["completed"] = ["type": "boolean", "description": "true completes it, false reopens it."]
        update["canceled"] = ["type": "boolean", "description": "true cancels it."]
        update["when"] = ["type": "string", "description": "As for add_todo; an empty string moves it to Anytime."]
        update["blocked_by"] = ["type": "string", "description": "Id of the to-do that must finish first. Sets the state to waiting; completing the blocker moves this back to todo."]
        let listNames = "today, evening, active (in progress or waiting), inbox, upcoming, anytime, someday, logbook, or a project, area or tag name"
        return [
            ["name": "add_todo", "description": "Create a to-do in Things 4. Returns it with its id.",
             "inputSchema": schema(todoFields, required: ["title"])],
            ["name": "add_todos", "description": "Create several to-dos at once (same fields as add_todo for each).",
             "inputSchema": schema(["todos": ["type": "array", "items": schema(todoFields, required: ["title"])]], required: ["todos"])],
            ["name": "add_project", "description": "Create a project, optionally with to-dos and headings. Good for a course, a plan or a series of exercises.",
             "inputSchema": schema([
                "title": ["type": "string"], "notes": ["type": "string"],
                "area": ["type": "string", "description": "Area title or id to file it under; created if missing."],
                "when": todoFields["when"]!, "deadline": todoFields["deadline"]!, "tags": todoFields["tags"]!,
                "todos": ["type": "array", "description": "To-dos in order. A string is a title; an object can have title, notes, when, deadline, reminder, tags, checklist. {\"type\": \"heading\", \"title\": \"Week 1\"} starts a heading.",
                          "items": ["anyOf": [["type": "string"], ["type": "object"]]]]
             ], required: ["title"])],
            ["name": "update_todo", "description": "Change a to-do or project: title, notes, schedule, tags, checklist, list, or complete/reopen it.",
             "inputSchema": schema(update, required: ["id"])],
            ["name": "complete_todo", "description": "Mark a to-do complete.",
             "inputSchema": schema(["id": ["type": "string"]], required: ["id"])],
            ["name": "get_todo", "description": "One to-do or project with its status, checklist, dates and notes. Use it to check whether the user finished something.",
             "inputSchema": schema(["id": ["type": "string"]], required: ["id"])],
            ["name": "list_todos", "description": "Open to-dos in a list: \(listNames).",
             "inputSchema": schema(["list": ["type": "string", "description": listNames]], required: ["list"])],
            ["name": "search_todos", "description": "Find to-dos by text, tag or status, e.g. everything tagged learning completed since yesterday.",
             "inputSchema": schema([
                "query": ["type": "string", "description": "Text to match in titles, notes, tags and checklists."],
                "status": ["type": "string", "enum": ["open", "completed", "canceled", "all"]],
                "tag": ["type": "string"],
                "list": ["type": "string", "description": listNames],
                "completed_since": ["type": "string", "description": "ISO date or date-time; implies status completed."],
                "limit": ["type": "integer"]
             ])],
            ["name": "list_projects", "description": "Open projects with their progress.", "inputSchema": schema([:])],
            ["name": "list_ideas", "description": "The user's Ideas: projects they haven't committed to yet, each with notes (Markdown) and a stage (raw, researching, ready).",
             "inputSchema": schema([:])],
            ["name": "get_idea", "description": "One idea with its full notes. Read it before researching so you build on what the user already wrote.",
             "inputSchema": schema(["id": ["type": "string"]], required: ["id"])],
            ["name": "add_idea", "description": "Save a project idea to Ideas, with notes. Use it when the user mentions something they might do later.",
             "inputSchema": schema([
                "title": ["type": "string"],
                "notes": ["type": "string", "description": "Markdown. A first line that pitches the idea in one sentence reads best in the list."],
                "area": ["type": "string", "description": "Area title or id; created if missing."],
                "stage": ["type": "string", "enum": ["raw", "researching", "ready"]],
                "tags": todoFields["tags"]!
             ], required: ["title"])],
            ["name": "update_idea", "description": "Add research to an idea or change it. Prefer append_notes with a dated Markdown section (## Research, 12 Nov) so the user's own notes stay intact. Concrete next steps written as - [ ] lines become to-dos when the idea is started.",
             "inputSchema": schema([
                "id": ["type": "string"],
                "append_notes": ["type": "string", "description": "Markdown added after the existing notes."],
                "notes": ["type": "string", "description": "Replaces all notes. Only when the user asks for a rewrite."],
                "title": ["type": "string"],
                "stage": ["type": "string", "enum": ["raw", "researching", "ready"]]
             ], required: ["id"])],
            ["name": "start_idea", "description": "Turn an idea into a project. Its - [ ] lines become to-dos. Now: an active project with the first step in Today. someday: true parks it in Someday instead. Only when the user says so.",
             "inputSchema": schema(["id": ["type": "string"], "someday": ["type": "boolean"]], required: ["id"])],
            ["name": "get_project", "description": "A project and its to-dos.",
             "inputSchema": schema(["id": ["type": "string"]], required: ["id"])],
            ["name": "list_areas", "description": "Areas and the projects in them.", "inputSchema": schema([:])],
            ["name": "add_area", "description": "Create an area, a top-level group such as Learning or Work that holds projects. Returns the existing area if one has this title.",
             "inputSchema": schema(["title": ["type": "string"]], required: ["title"])],
            ["name": "list_tags", "description": "All tags in use.", "inputSchema": schema([:])],
            ["name": "log_time", "description": "Log time the user spent on a to-do (a focus session, a study block). It adds to the to-do's tracked time.",
             "inputSchema": schema([
                "id": ["type": "string"],
                "minutes": ["type": "number"],
                "start": ["type": "string", "description": "ISO date-time the session started (optional)."],
                "end": ["type": "string", "description": "ISO date-time it ended (optional; defaults to now)."],
                "note": ["type": "string"]
             ], required: ["id"])],
            ["name": "get_time", "description": "Time tracked: for one to-do or project (pass id), or totals per to-do since a day (pass since: today, monday, 2026-11-01).",
             "inputSchema": schema(["id": ["type": "string"], "since": ["type": "string"]])],
            ["name": "show_in_things", "description": "Bring Things 4 forward showing a to-do, project or list (today, inbox…).",
             "inputSchema": schema(["id": ["type": "string", "description": "A to-do or project id, or a list name."]], required: ["id"])]
        ]
    }

    private static func runTool(_ name: String, _ args: [String: Any]) -> Reply {
        let id = (args["id"] as? String)?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        switch name {
        case "add_todo": return call("POST", "/tasks", body: args)
        case "add_todos": return call("POST", "/tasks", body: args["todos"] ?? [])
        case "add_project": return call("POST", "/projects", body: args)
        case "update_todo": return call("PATCH", "/tasks/\(id)", body: args.filter { $0.key != "id" })
        case "complete_todo": return call("POST", "/tasks/\(id)/complete")
        case "get_todo": return call("GET", "/tasks/\(id)")
        case "get_project": return call("GET", "/projects/\(id)")
        case "list_todos":
            let list = (args["list"] as? String ?? "today").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "today"
            return call("GET", "/lists/\(list)")
        case "search_todos":
            var query: [String: String] = [:]
            for (key, value) in args { query[key == "query" ? "q" : key] = "\(value)" }
            return call("GET", "/tasks", query: query)
        case "list_projects": return call("GET", "/projects")
        case "list_ideas": return call("GET", "/ideas")
        case "get_idea": return call("GET", "/tasks/\(id)")
        case "add_idea": return call("POST", "/ideas", body: args)
        case "update_idea": return call("PATCH", "/tasks/\(id)", body: args.filter { $0.key != "id" })
        case "start_idea": return call("POST", "/ideas/\(id)/start", body: args.filter { $0.key != "id" })
        case "list_areas": return call("GET", "/areas")
        case "add_area": return call("POST", "/areas", body: args)
        case "list_tags": return call("GET", "/tags")
        case "show_in_things": return call("POST", "/show", body: ["id": args["id"] ?? ""])
        case "log_time": return call("POST", "/tasks/\(id)/time", body: args.filter { $0.key != "id" })
        case "get_time":
            if !id.isEmpty { return call("GET", "/tasks/\(id)/time") }
            return call("GET", "/time", query: ["since": args["since"] as? String ?? "today"])
        default: return Reply(status: 404, json: ["error": "Unknown tool \(name)."], text: "")
        }
    }

    /// JSON-RPC 2.0, one message per line on stdin/stdout (MCP stdio transport).
    static func runMCP() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            guard let id, !(id is NSNull) else { continue } // notifications need no reply

            var result: Any?
            var error: [String: Any]?
            switch method {
            case "initialize":
                if source == nil, let client = (params["clientInfo"] as? [String: Any])?["name"] as? String { source = client }
                result = [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "things4", "title": "Things 4", "version": ThingsAPI.version],
                    "instructions": "Things 4 is the user's to-do app. Use add_todo or add_project to give the user tasks, list_ideas / get_idea / update_idea to research the projects they're still thinking about, and get_todo or search_todos (tag: \(source ?? "your name"), completed_since) to see what they finished. Everything you create is tagged “\(source ?? "with your client name")” automatically. Naming a project or area that doesn't exist creates it."
                ]
            case "ping":
                result = [String: Any]()
            case "tools/list":
                result = ["tools": tools]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let reply = runTool(name, params["arguments"] as? [String: Any] ?? [:])
                let ok = (200..<300).contains(reply.status)
                let text = reply.json.map(pretty) ?? (reply.text.isEmpty ? "HTTP \(reply.status)" : reply.text)
                var content: [String: Any] = ["content": [["type": "text", "text": text]], "isError": !ok]
                if ok, let object = reply.json as? [String: Any] { content["structuredContent"] = object }
                else if ok, let array = reply.json as? [Any] { content["structuredContent"] = ["items": array] }
                result = content
            default:
                error = ["code": -32601, "message": "Method not found: \(method)"]
            }
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let error { response["error"] = error } else { response["result"] = result ?? [String: Any]() }
            if let data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        }
        exit(0)
    }

    // MARK: - CLI

    private static let help = """
    things4 — add and read Things 4 to-dos from the terminal or scripts.

      things4 add "Read chapter 3" [--when today] [--deadline fri] [--reminder "tomorrow 9am"]
                  [--tags learning,rust] [--list "Learn Rust"] [--heading "Week 1"]
                  [--notes "…"] [--checklist "step one" --checklist "step two"]
      things4 project "Learn Rust" [--area Learning] --todo "Install rustup" --todo "Ownership chapter"
      things4 area "Learning"         (projects and areas named in --list / --area are created if missing)
      things4 today | inbox | upcoming | anytime | someday | logbook | list <project, area or tag>
      things4 search <text> [--status completed] [--tag learning] [--completed-since 2026-11-01]
      things4 get <id>        things4 complete <id>        things4 reopen <id>
      things4 update <id> [--title …] [--when …] [--append-notes …] [--add-tags …] [--completed true]
      things4 time <id> 40 [--note "…"]   log 40 minutes on a to-do
      things4 time <id>                   its tracked time     things4 time [--since monday]   totals
      things4 show <id | today | …>     things4 json '[{"type":"to-do","attributes":{"title":"…"}}]'
      things4 mcp             run as an MCP server (stdio) for AI agents
      things4 api             print the API address and token

    Add --source <name> to tag what you create. Add --json to print the raw JSON. Things 4 opens in the background if it isn't running.
    """

    /// "--tags a,b --checklist x --checklist y" → ["tags": "a,b", "checklist": ["x", "y"]]
    private static func options(_ args: ArraySlice<String>) -> (positional: [String], options: [String: Any]) {
        var positional: [String] = []
        var options: [String: Any] = [:]
        var index = args.startIndex
        while index < args.endIndex {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                let next = args.index(after: index)
                let value: String
                if next < args.endIndex, !args[next].hasPrefix("--") { value = args[next]; index = args.index(after: next) }
                else { value = "true"; index = next }
                switch options[key] {
                case let list as [String]: options[key] = list + [value]
                case let single as String: options[key] = [single, value]
                default: options[key] = ["checklist", "todo", "checklist-items"].contains(key) ? [value] : value
                }
            } else {
                positional.append(arg)
                index = args.index(after: index)
            }
        }
        return (positional, options)
    }

    private static func readable(_ timestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(date.startOfDay == Date().startOfDay ? "jmm" : "EEE d MMM jmm")
        return formatter.string(from: date)
    }

    private static func line(for item: [String: Any]) -> String {
        if (item["type"] as? String) == "heading" { return "\n" + (item["title"] as? String ?? "").uppercased() }
        let done = (item["status"] as? String) == "completed"
        var parts = [(done ? "☑" : "☐") + " " + (item["title"] as? String ?? "")]
        if let project = (item["project"] as? [String: Any])?["title"] as? String { parts.append("· " + project) }
        if let deadline = item["deadline"] as? String { parts.append("⚑ " + deadline) }
        if let reminder = item["reminder"] as? String { parts.append("🔔 " + readable(reminder)) }
        if let tags = item["tags"] as? [String], !tags.isEmpty { parts.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        parts.append("[\(item["id"] as? String ?? "")]")
        return parts.joined(separator: "  ")
    }

    static func runCLI(_ arguments: [String]) -> Never {
        var args = arguments
        let raw = args.contains("--json")
        args.removeAll { $0 == "--json" }
        guard let command = args.first, !["help", "-h", "--help"].contains(command) else { print(help); exit(0) }
        if command == "mcp" { runMCP() }
        let (positional, opts) = options(args.dropFirst())
        let first = positional.first ?? ""
        let encodedFirst = first.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? first

        let reply: Reply
        switch command {
        case "add":
            guard !positional.isEmpty else { print("Usage: things4 add \"Title\" [--when today] …"); exit(2) }
            var body = opts
            body[positional.count > 1 ? "titles" : "title"] = positional.count > 1 ? positional : first
            reply = call("POST", "/tasks", body: body)
        case "project":
            var body = opts
            body["title"] = first
            body["to-dos"] = opts["todo"] ?? []
            body.removeValue(forKey: "todo")
            reply = call("POST", "/projects", body: body)
        case "today", "inbox", "upcoming", "anytime", "someday", "logbook", "evening", "trash":
            reply = call("GET", "/lists/\(command)")
        case "list":
            reply = call("GET", "/lists/\(encodedFirst)")
        case "search":
            var query = opts.mapValues { "\($0)" }
            query["q"] = positional.joined(separator: " ")
            reply = call("GET", "/tasks", query: query)
        case "get": reply = call("GET", "/tasks/\(encodedFirst)")
        case "complete": reply = call("POST", "/tasks/\(encodedFirst)/complete")
        case "reopen": reply = call("POST", "/tasks/\(encodedFirst)/reopen")
        case "update": reply = call("PATCH", "/tasks/\(encodedFirst)", body: opts)
        case "delete", "trash-item": reply = call("DELETE", "/tasks/\(encodedFirst)")
        case "time":
            if positional.count >= 2 {
                var body = opts
                body["minutes"] = positional[1]
                reply = call("POST", "/tasks/\(encodedFirst)/time", body: body)
            } else if !first.isEmpty {
                reply = call("GET", "/tasks/\(encodedFirst)/time")
            } else {
                reply = call("GET", "/time", query: ["since": opts["since"] as? String ?? "today"])
            }
        case "projects": reply = call("GET", "/projects")
        case "area": reply = call("POST", "/areas", body: ["title": first])
        case "areas": reply = call("GET", "/areas")
        case "tags": reply = call("GET", "/tags")
        case "show": reply = call("POST", "/show", body: ["id": first])
        case "json":
            let data = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) ?? []
            reply = call("POST", "/json", body: data)
        case "api":
            let object = APIConfig.read()
            print("URL:   \(object["url"] as? String ?? "http://127.0.0.1:\(APIConfig.defaultPort)/v1")")
            print("Token: \(object["token"] as? String ?? "(open Things 4 once to create it)")")
            print("File:  \(APIConfig.fileURL.path)")
            exit(0)
        default:
            print("Unknown command “\(command)”.\n\n" + help)
            exit(2)
        }

        let ok = (200..<300).contains(reply.status)
        if !ok {
            let message = (reply.json as? [String: Any])?["error"] as? String ?? (reply.text.isEmpty ? "HTTP \(reply.status)" : reply.text)
            FileHandle.standardError.write(Data("things4: \(message)\n".utf8))
            exit(1)
        }
        if raw { print(pretty(reply.json)); exit(0) }
        if command == "time", let object = reply.json as? [String: Any] {
            if let task = object["task"] as? [String: Any] {
                print("Logged \((object["entry"] as? [String: Any])?["minutes"] ?? 0)m on “\(task["title"] ?? "")”, \(task["tracked"] ?? "0m") in total.")
            } else if let rows = object["tasks"] as? [[String: Any]] {
                print("\(object["total"] ?? "0m") since \(readable(object["since"] as? String ?? ""))")
                for row in rows { print("  \(row["tracked"] ?? "")\t\(row["title"] ?? "")  [\(row["id"] ?? "")]") }
            } else {
                print("\(object["title"] ?? ""): \(object["tracked"] ?? "0m")")
                for entry in object["entries"] as? [[String: Any]] ?? [] {
                    print("  \(readable(entry["start"] as? String ?? ""))  \(entry["minutes"] ?? 0)m" + ((entry["source"] as? String).map { "  · " + $0 } ?? ""))
                }
            }
            exit(0)
        }
        switch reply.json {
        case let items as [[String: Any]]:
            if items.isEmpty { print("Nothing here.") }
            for item in items { print(line(for: item)) }
        case let item as [String: Any] where item["id"] != nil && item["type"] == nil:
            print("▢ " + (item["title"] as? String ?? "") + "  [\(item["id"] as? String ?? "")]")
        case let item as [String: Any] where item["id"] != nil:
            print(line(for: item))
            if let todos = item["to-dos"] as? [[String: Any]] { todos.forEach { print("  " + line(for: $0)) } }
            if let notes = item["notes"] as? String, !notes.isEmpty, command == "get" { print("\n" + notes) }
        case let tags as [String]:
            print(tags.joined(separator: "\n"))
        default:
            print(pretty(reply.json))
        }
        exit(0)
    }

    // MARK: - Install

    /// A `things4` script in ~/.local/bin that runs this app's CLI.
    static func installCLI() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("things4")
        let executable = Bundle.main.executablePath ?? "/Applications/Things 4.app/Contents/MacOS/Things4"
        let script = "#!/bin/sh\n# Things 4 command-line tool. Run `things4 help`.\nexec \"\(executable)\" --cli \"$@\"\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The snippet to paste into an MCP client config (Claude Code, Claude Desktop, Cursor…).
    static var mcpConfig: String {
        let executable = Bundle.main.executablePath ?? "/Applications/Things 4.app/Contents/MacOS/Things4"
        return """
        {
          "mcpServers": {
            "things4": {
              "command": "\(executable)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }
}
