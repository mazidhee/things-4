import AppKit
import Network

/// Where other programs find the API: api.json next to the database holds the
/// port and the token. Readable only by you (0600); the CLI and MCP server read it.
enum APIConfig {
    static let defaultPort: UInt16 = 7474

    static var directory: URL {
        let override = ProcessInfo.processInfo.environment["THINGS4_DB"] ?? ""
        return override.isEmpty
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Things4")
            : URL(fileURLWithPath: override).deletingLastPathComponent()
    }

    static var fileURL: URL { directory.appendingPathComponent("api.json") }

    static var port: UInt16 {
        if let value = ProcessInfo.processInfo.environment["THINGS4_API_PORT"].flatMap(UInt16.init) { return value }
        return Preferences.apiPort
    }

    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The bearer token, made on first use.
    static var token: String {
        if let token = read()["token"] as? String, token.count >= 32 { return token }
        let token = newToken()
        write(token: token, port: port)
        return token
    }

    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    static func regenerateToken() {
        write(token: newToken(), port: port)
    }

    static func write(token: String? = nil, port: UInt16) {
        let token = token ?? self.token
        let object: [String: Any] = ["url": "http://127.0.0.1:\(port)/v1", "port": Int(port), "token": token,
                                     "app": "Things 4", "version": ThingsAPI.version]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// A small HTTP/1.1 server on the loopback interface only. Every request except
/// GET /v1/health needs `Authorization: Bearer <token>`.
final class APIServer {
    static let shared = APIServer()
    static let statusDidChange = Notification.Name("Things4.apiStatusDidChange")

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "things4.api")
    private(set) var listeningPort: UInt16?
    private(set) var lastError: String?

    var isRunning: Bool { listeningPort != nil }
    /// True once the app has started the server (test runs leave it off).
    private(set) var isManaged = false

    /// Starts or stops to match the Settings toggle.
    func refresh() {
        isManaged = true
        if Preferences.apiEnabled { start() } else { stop() }
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: APIConfig.port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listeningPort = APIConfig.port
                        self.lastError = nil
                        APIConfig.write(port: APIConfig.port)
                    case .failed(let error):
                        self.listeningPort = nil
                        self.lastError = "Port \(APIConfig.port) is unavailable (\(error.localizedDescription))."
                        self.listener?.cancel()
                        self.listener = nil
                    case .cancelled:
                        self.listeningPort = nil
                    default: break
                    }
                    NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                let response = DispatchQueue.main.sync { self.respond(to: request) }
                self.send(response, on: connection)
            case .invalid:
                self.send(HTTPResponse(status: 400, body: ["error": "Malformed HTTP request."]), on: connection)
            case .incomplete:
                if isComplete || error != nil || buffer.count > 4 << 20 { connection.cancel() }
                else { self.receive(connection, buffer: buffer) }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Routing

    func respond(to request: HTTPRequest) -> HTTPResponse {
        var parts = request.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if parts.first == "v1" { parts.removeFirst() }
        let method = request.method

        if method == "OPTIONS" { return HTTPResponse(status: 204, body: nil) }
        if parts == ["health"] || parts.isEmpty && method == "GET" && request.header("authorization") == nil {
            return HTTPResponse(status: 200, body: ["ok": true, "app": "Things 4", "version": ThingsAPI.version])
        }
        guard authorized(request) else {
            return HTTPResponse(status: 401, body: ["error": "Missing or wrong token. Send Authorization: Bearer <token> — the token is in \(APIConfig.fileURL.path) and Settings › API."])
        }

        let body: Any?
        if request.body.isEmpty { body = nil }
        else if let decoded = try? JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed]) { body = decoded }
        else { return HTTPResponse(status: 400, body: ["error": "The request body is not valid JSON."]) }
        let object = body as? [String: Any] ?? [:]
        // Agents name themselves with X-Things-Source; new items get that as a tag.
        let source = request.header("x-things-source")
        func withSource(_ params: [String: Any]) -> [String: Any] {
            guard let source, params["source"] == nil else { return params }
            var params = params
            params["source"] = source
            return params
        }

        do {
            switch (method, parts.first ?? "", parts.count) {
            case ("GET", "", 0):
                return HTTPResponse(status: 200, body: Self.index)
            case ("GET", "lists", 2):
                return .ok(try ThingsAPI.list(parts[1]).map(ThingsAPI.encode))
            case ("GET", "tasks", 1):
                return .ok(try ThingsAPI.query(request.query).map(ThingsAPI.encode))
            case ("POST", "tasks", 1):
                let entries = (body as? [Any]) ?? [object]
                var created: [TaskItem] = []
                for case let entry as [String: Any] in entries { created += try ThingsAPI.add(withSource(entry)) }
                return HTTPResponse(status: 201, body: created.map(ThingsAPI.encode))
            case ("GET", "tasks", 2):
                return .ok(ThingsAPI.encode(try ThingsAPI.item(parts[1])))
            case ("PATCH", "tasks", 2), ("PUT", "tasks", 2):
                var params = object
                params["id"] = parts[1]
                return .ok(ThingsAPI.encode(try ThingsAPI.update(params)))
            case ("POST", "tasks", 3) where parts[2] == "complete":
                return .ok(ThingsAPI.encode(try ThingsAPI.complete(parts[1])))
            case ("POST", "tasks", 3) where parts[2] == "reopen":
                return .ok(ThingsAPI.encode(try ThingsAPI.update(["id": parts[1], "completed": false])))
            case ("POST", "tasks", 3) where parts[2] == "time":
                return HTTPResponse(status: 201, body: try ThingsAPI.logTime(parts[1], object, source: source))
            case ("GET", "tasks", 3) where parts[2] == "time":
                return .ok(try ThingsAPI.time(parts[1]))
            case ("GET", "time", 1):
                return .ok(try ThingsAPI.timeReport(request.query))
            case ("DELETE", "time", 2):
                TaskStore.shared.deleteTimeEntry(parts[1])
                return .ok(["ok": true])
            case ("DELETE", "tasks", 2):
                return .ok(ThingsAPI.encode(try ThingsAPI.trash(parts[1])))
            case ("GET", "projects", 1):
                return .ok(ThingsAPI.projects())
            case ("GET", "projects", 2):
                let project = try ThingsAPI.item(parts[1])
                var out = ThingsAPI.encode(project)
                out["to-dos"] = TaskStore.shared.children(of: project.id).filter { !$0.isHeading && $0.status != .trashed }.map(ThingsAPI.encode)
                return .ok(out)
            case ("POST", "projects", 1):
                return HTTPResponse(status: 201, body: try ThingsAPI.addProject(withSource(object)).map(ThingsAPI.encode))
            case ("GET", "ideas", 1):
                return .ok(TaskStore.shared.ideas.map(ThingsAPI.encode))
            case ("POST", "ideas", 1):
                return HTTPResponse(status: 201, body: ThingsAPI.encode(try ThingsAPI.addIdea(withSource(object))))
            case ("POST", "ideas", 3) where parts[2] == "start":
                return .ok(ThingsAPI.encode(try ThingsAPI.startIdea(parts[1], someday: ThingsAPI.bool(object, "someday") == true)))
            case ("GET", "areas", 1):
                return .ok(ThingsAPI.areas())
            case ("POST", "areas", 1):
                return HTTPResponse(status: 201, body: try ThingsAPI.addArea(object))
            case ("GET", "tags", 1):
                return .ok(ThingsAPI.tags())
            case ("POST", "json", 1):
                return HTTPResponse(status: 201, body: try ThingsAPI.json(object["data"] ?? body ?? [], source: source).map(ThingsAPI.encode))
            case ("POST", "show", 1):
                try ThingsAPI.show(id: ThingsAPI.string(object, "id"), query: ThingsAPI.string(object, "query"))
                return .ok(["ok": true])
            default:
                return HTTPResponse(status: 404, body: ["error": "No endpoint \(method) \(request.path). GET /v1 lists them."])
            }
        } catch let failure as ThingsAPI.Failure {
            return HTTPResponse(status: failure.status, body: ["error": failure.message])
        } catch {
            return HTTPResponse(status: 500, body: ["error": error.localizedDescription])
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        let expected = APIConfig.token
        var given = request.header("x-things-token") ?? ""
        if let header = request.header("authorization"), header.lowercased().hasPrefix("bearer ") {
            given = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard given.utf8.count == expected.utf8.count else { return false }
        return zip(given.utf8, expected.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static let index: [String: Any] = [
        "app": "Things 4",
        "endpoints": [
            "GET /v1/lists/{today|evening|inbox|upcoming|anytime|someday|logbook|<project, area or tag>}",
            "GET /v1/tasks?q=&status=open|completed|canceled|all&tags=&list=&completed-since=&modified-since=&limit=",
            "POST /v1/tasks  {title | titles, notes, when, deadline, reminder, tags, checklist-items, list, area, heading, source, completed}  (or an array)",
            "GET /v1/tasks/{id}",
            "GET /v1/ideas · POST /v1/ideas {title, notes, area, stage: raw|researching|ready, tags} · POST /v1/ideas/{id}/start {someday}",
            "PATCH /v1/tasks/{idea id} {append-notes, notes, title, stage} edits an idea",
            "PATCH /v1/tasks/{id}  {title, notes, prepend-notes, append-notes, when, deadline, reminder, tags, add-tags, checklist-items, append-checklist-items, list, heading, completed, canceled}",
            "POST /v1/tasks/{id}/complete · POST /v1/tasks/{id}/reopen · DELETE /v1/tasks/{id} (moves to Trash)",
            "POST /v1/tasks/{id}/time {minutes | seconds | start+end, start, end, note} logs focused time · GET /v1/tasks/{id}/time lists it (a project's includes its to-dos) · tasks carry tracked_minutes",
            "GET /v1/time?since=today|monday|2026-11-01 totals time by to-do · DELETE /v1/time/{entry id}",
            "GET /v1/projects · GET /v1/projects/{id} · POST /v1/projects {title, notes, area, when, deadline, tags, to-dos: [string | {title, notes, …} | {type: heading, title}]}",
            "GET /v1/areas · POST /v1/areas {title} · GET /v1/tags",
            "Header X-Things-Source: <agent name> (or a source field) tags new items with that name and notes “Added by …”. A list or area that doesn't exist yet is created.",
            "POST /v1/json  (Things 3 JSON: [{type: to-do | project, attributes: {…}}])",
            "POST /v1/show {id | query}"
        ],
        "when": "today, evening, tomorrow, anytime, someday, 2026-11-20, friday, in 3 days, tomorrow 9am, 2026-11-20@14:30"
    ]
}

// MARK: - HTTP

struct HTTPRequest {
    enum Parse { case complete(HTTPRequest), incomplete, invalid }

    var method: String
    var path: String
    var query: [String: Any]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 64 << 10 ? .invalid : .incomplete }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }

        let target = String(start[1])
        let components = URLComponents(string: target)
        var query: [String: Any] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: start[0].uppercased(), path: components?.path ?? target, query: query,
                                     headers: headers, body: Data(body.prefix(length))))
    }
}

struct HTTPResponse {
    var status: Int
    var body: Any?

    static func ok(_ body: Any) -> HTTPResponse { HTTPResponse(status: 200, body: body) }

    var serialized: Data {
        let reasons = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                       404: "Not Found", 500: "Internal Server Error"]
        let payload = body.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) } ?? Data()
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + payload
    }
}

// MARK: - URL scheme

/// things4:///add?title=…, the same commands and parameters as Things 3's things:/// URLs.
/// `update`, `update-project` and `json` with updates need auth-token (Settings › API).
enum URLCommands {
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "things4" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var params: [String: Any] = [:]
        for item in components?.queryItems ?? [] { params[item.name] = item.value ?? "" }
        let host = url.host ?? ""
        let command = (host.isEmpty ? url.pathComponents.dropFirst().first : host)?.lowercased() ?? ""

        // things4://task/<id> (used by the Reminders mirror) and things4:///show?id=…
        if command == "task", let id = url.pathComponents.dropFirst().first {
            try? ThingsAPI.show(id: id, query: nil)
            return
        }
        guard Preferences.apiEnabled else {
            fail(params, "Other apps can't use Things 4 right now. Turn it on in Settings › API.")
            return
        }
        do {
            var created: [TaskItem] = []
            switch command {
            case "add":
                let titles = ThingsAPI.strings(params, "titles") ?? ThingsAPI.string(params, "title").map { [$0] } ?? []
                if ThingsAPI.bool(params, "show-quick-entry") == true || titles.allSatisfy(\.isEmpty) {
                    QuickEntryWindowController.shared.show(prefill: titles.first ?? "", notes: ThingsAPI.string(params, "notes") ?? "")
                    return
                }
                created = try ThingsAPI.add(params)
            case "add-project":
                created = try ThingsAPI.addProject(params)
            case "update", "update-project":
                try requireToken(params)
                created = [try ThingsAPI.update(params)]
            case "json":
                let data = ThingsAPI.string(params, "data") ?? "[]"
                if data.contains("\"update\"") { try requireToken(params) }
                created = try ThingsAPI.json(data)
            case "show", "search":
                try ThingsAPI.show(id: ThingsAPI.string(params, "id"), query: ThingsAPI.string(params, "query"))
            case "version":
                succeed(params, extra: ["x-things-scheme-version": "2", "x-things-client-version": ThingsAPI.version])
                return
            default:
                throw ThingsAPI.Failure("Things 4 doesn't know the command “\(command)”.")
            }
            if ThingsAPI.bool(params, "reveal") == true, let first = created.first {
                try? ThingsAPI.show(id: first.id, query: nil)
            }
            succeed(params, extra: created.isEmpty ? [:] : ["x-things-id": created.map(\.id).joined(separator: ",")])
        } catch let failure as ThingsAPI.Failure {
            fail(params, failure.message)
        } catch {
            fail(params, error.localizedDescription)
        }
    }

    private static func requireToken(_ params: [String: Any]) throws {
        guard ThingsAPI.string(params, "auth-token") == APIConfig.token else {
            throw ThingsAPI.Failure("This command changes existing to-dos, so it needs auth-token. Copy it from Settings › API.", status: 401)
        }
    }

    private static func succeed(_ params: [String: Any], extra: [String: String]) {
        guard let target = ThingsAPI.string(params, "x-success"), var callback = URLComponents(string: target) else { return }
        callback.queryItems = (callback.queryItems ?? []) + extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let url = callback.url { NSWorkspace.shared.open(url) }
    }

    private static func fail(_ params: [String: Any], _ message: String) {
        if let target = ThingsAPI.string(params, "x-error"), var callback = URLComponents(string: target) {
            callback.queryItems = (callback.queryItems ?? []) + [URLQueryItem(name: "errorMessage", value: message)]
            if let url = callback.url { NSWorkspace.shared.open(url) }
            return
        }
        NSLog("Things 4 URL: \(message)")
        let alert = NSAlert()
        alert.messageText = "Couldn't Complete the Link"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
