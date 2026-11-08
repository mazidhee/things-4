import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case commandCode
    case openCode
    case openAI
    case anthropic
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandCode: return "CommandCode"
        case .openCode: return "OpenCode"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .custom: return "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .commandCode: return "https://api.commandcode.ai/provider/v1"
        case .openCode: return "https://opencode.ai/inference/openai/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .custom: return ""
        }
    }

    var modelsURL: String? {
        switch self {
        case .commandCode: return "https://api.commandcode.ai/provider/v1/models"
        case .openCode: return "https://opencode.ai/inference/v1/models"
        case .openAI: return "https://api.openai.com/v1/models"
        case .anthropic: return "https://api.anthropic.com/v1/models"
        case .custom: return nil
        }
    }

    var defaultModel: String {
        switch self {
        case .commandCode: return "deepseek/deepseek-v4.1-flash"
        case .openCode: return "big-pickle"
        case .openAI: return "gpt-5.4-mini"
        case .anthropic: return "claude-sonnet-5"
        case .custom: return ""
        }
    }

    var keyHint: String {
        switch self {
        case .commandCode: return "user_… from commandcode.ai"
        case .openCode: return "Key from the OpenCode console"
        case .openAI: return "sk-…"
        case .anthropic: return "sk-ant-…"
        case .custom: return "Any bearer token"
        }
    }

    var keychainAccount: String { "apikey." + rawValue }
}

enum AIFormat {
    case openAI
    case anthropic
}

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoints: [String]

    var format: AIFormat {
        if endpoints.contains("/messages") && !endpoints.contains("/chat/completions") {
            return .anthropic
        }
        return .openAI
    }
}

struct AIMessage {
    var role: String
    var content: String
}

enum AIFailure: LocalizedError {
    case missingKey
    case badURL(String)
    case http(Int, String)
    case empty
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No API key. Open Settings and paste one."
        case .badURL(let value):
            return "That base URL is not valid: \(value)"
        case .http(let code, let body):
            return "The provider returned HTTP \(code). \(body.prefix(240))"
        case .empty:
            return "The model returned an empty response."
        case .decoding(let message):
            return "Could not read the model's response: \(message)"
        }
    }
}

enum AISettings {
    private static let defaults = UserDefaults.standard

    static var provider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .commandCode }
        set { defaults.set(newValue.rawValue, forKey: "ai.provider") }
    }

    static func baseURL(for provider: AIProvider) -> String {
        let stored = defaults.string(forKey: "ai.base." + provider.rawValue) ?? ""
        return stored.isEmpty ? provider.defaultBaseURL : stored
    }

    static func setBaseURL(_ value: String, for provider: AIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == provider.defaultBaseURL || trimmed.isEmpty {
            defaults.removeObject(forKey: "ai.base." + provider.rawValue)
        } else {
            defaults.set(trimmed, forKey: "ai.base." + provider.rawValue)
        }
    }

    static func model(for provider: AIProvider) -> String {
        let stored = defaults.string(forKey: "ai.model." + provider.rawValue) ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    static func setModel(_ value: String, for provider: AIProvider) {
        defaults.set(value, forKey: "ai.model." + provider.rawValue)
    }

    static func format(for provider: AIProvider) -> AIFormat {
        let raw = defaults.string(forKey: "ai.format." + provider.rawValue) ?? ""
        return raw == "anthropic" ? .anthropic : .openAI
    }

    static func setFormat(_ format: AIFormat, for provider: AIProvider) {
        defaults.set(format == .anthropic ? "anthropic" : "openai", forKey: "ai.format." + provider.rawValue)
    }

    static func key(for provider: AIProvider) -> String {
        if ProcessInfo.processInfo.environment["THINGS4_IGNORE_KEYS"] == "1" { return "" }
        return Keychain.read(account: provider.keychainAccount) ?? ""
    }

    static func setKey(_ value: String, for provider: AIProvider) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Keychain.delete(account: provider.keychainAccount)
        } else {
            Keychain.write(value.trimmingCharacters(in: .whitespacesAndNewlines), account: provider.keychainAccount)
        }
    }

    static func hasKey(for provider: AIProvider) -> Bool {
        !key(for: provider).isEmpty
    }
}

enum AIClient {

    static func complete(system: String, messages: [AIMessage], maxTokens: Int = 2200) async throws -> String {
        let provider = AISettings.provider
        let key = AISettings.key(for: provider)
        guard !key.isEmpty else { throw AIFailure.missingKey }
        let model = AISettings.model(for: provider)
        let base = normalized(AISettings.baseURL(for: provider))

        switch AISettings.format(for: provider) {
        case .anthropic:
            return try await anthropic(base: base, key: key, model: model, system: system,
                                       messages: messages, maxTokens: maxTokens)
        case .openAI:
            return try await openAI(base: base, key: key, model: model, system: system,
                                    messages: messages, maxTokens: maxTokens)
        }
    }

    private static func normalized(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func openAI(base: String, key: String, model: String, system: String,
                               messages: [AIMessage], maxTokens: Int) async throws -> String {
        guard let url = URL(string: base + "/chat/completions") else { throw AIFailure.badURL(base) }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]]
                + messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": 0.25,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]] else {
            throw AIFailure.empty
        }
        guard let message = choices.first?["message"] as? [String: Any] else { throw AIFailure.empty }

        if let text = message["content"] as? String, !text.isEmpty { return text }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty { return reasoning }
        throw AIFailure.empty
    }

    private static func anthropic(base: String, key: String, model: String, system: String,
                                  messages: [AIMessage], maxTokens: Int) async throws -> String {
        guard let url = URL(string: base + "/messages") else { throw AIFailure.badURL(base) }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0.25,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw AIFailure.empty
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIFailure.empty }
        return text
    }

    private static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIFailure.http(http.statusCode, body)
        }
    }

    static func models(provider: AIProvider, key: String) async throws -> [AIModel] {
        let base = normalized(AISettings.baseURL(for: provider))
        var candidates: [String] = []
        if let modelsURL = provider.modelsURL { candidates.append(modelsURL) }
        if !base.isEmpty { candidates.append(base + "/models") }

        var lastError: Error?
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                if !key.isEmpty {
                    if provider == .anthropic || AISettings.format(for: provider) == .anthropic {
                        request.setValue(key, forHTTPHeaderField: "x-api-key")
                        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    } else {
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                try validate(response, data)
                let models = try parseModels(data)
                if !models.isEmpty { return models }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private static func parseModels(_ data: Data) throws -> [AIModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let items = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["name"] as? String) ?? (item["display_name"] as? String) ?? id
            let endpoints = (item["supported_endpoints"] as? [String]) ?? []
            return AIModel(id: id, name: name, endpoints: endpoints)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func testConnection() async throws -> String {
        let reply = try await complete(system: "You are a connection test. Reply with exactly: connected",
                                       messages: [AIMessage(role: "user", content: "Say connected.")],
                                       maxTokens: 20)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
