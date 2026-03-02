import Foundation

enum StructuringProviderKind: String, CaseIterable, Identifiable {
    case mock
    case openAI
    case doubao

    var id: String { rawValue }
}

enum StructuringError: Error {
    case unavailable(String)
    case invalidResponse(String)
}

struct StructuringPrompt {
    static let jsonSchema = """
    {
      "type": "object",
      "properties": {
        "type": { "type": "string", "enum": ["task", "idea", "note"] },
        "title": { "type": "string" },
        "details": { "type": "string" },
        "priority": { "type": "string", "enum": ["low", "normal", "high"] },
        "dueDate": { "type": ["string", "null"], "format": "date-time" },
        "tags": { "type": "array", "items": { "type": "string" } },
        "project": { "type": ["string", "null"] }
      },
      "required": ["type", "title", "details", "priority", "dueDate", "tags", "project"],
      "additionalProperties": false
    }
    """

    static func buildPrompt(for text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        You are a personal assistant. Convert the input into a single JSON object that matches this schema exactly.
        Only return JSON (no markdown, no commentary).

        JSON Schema:
        \(jsonSchema)

        Rules:
        - "dueDate" must be ISO-8601 date-time (YYYY-MM-DDTHH:mm). If time is unknown, use YYYY-MM-DD.
        - Resolve relative dates like "tomorrow" or "next Friday 6pm" using the current date/time.
        - "priority" defaults to "normal" if not mentioned.
        - "tags" should be concise single words (no # prefix).
        - "project" should be a short name or null if unknown.

        Current time: \(DueDateParser.referenceTimestamp())
        Time zone: \(TimeZone.current.identifier)

        Input:
        \(trimmedText)
        """
    }

}

struct StructuringParser {

    static func decodeDraft(from jsonString: String) throws -> StructuredDraft {
        let data = Data(jsonString.utf8)
        let decoder = JSONDecoder()
        let response = try decoder.decode(StructuredResponse.self, from: data)

        let dueDate = DueDateParser.parse(response.dueDate)

        return StructuredDraft(
            type: response.itemType,
            title: response.title,
            details: response.details,
            priority: response.itemPriority,
            dueDate: dueDate,
            tags: response.tags,
            project: response.project
        )
    }

    static func validate(_ draft: StructuredDraft) -> StructuredDraft {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedTitle: String
        if !trimmedTitle.isEmpty {
            resolvedTitle = trimmedTitle
        } else if trimmedDetails.isEmpty {
            resolvedTitle = "Untitled"
        } else {
            resolvedTitle = String(trimmedDetails.prefix(40))
        }

        let tags = draft.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let project = draft.project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedProject = (project?.isEmpty ?? true) ? nil : project

        return StructuredDraft(
            type: draft.type,
            title: resolvedTitle,
            details: trimmedDetails,
            priority: draft.priority,
            dueDate: draft.dueDate,
            tags: tags,
            project: resolvedProject
        )
    }

}

private struct StructuredResponse: Decodable {
    let type: String
    let title: String
    let details: String
    let priority: String
    let dueDate: String?
    let tags: [String]
    let project: String?

    var itemType: ItemType {
        ItemType(rawValue: type) ?? .note
    }

    var itemPriority: ItemPriority {
        switch priority.lowercased() {
        case "low":
            return .low
        case "high":
            return .high
        default:
            return .normal
        }
    }
}

enum StructuringFixtures {
    static let sampleJSON = """
    {
      "type": "task",
      "title": "Follow up with Sam",
      "details": "Follow up with Sam about the partnership deck next week.",
      "priority": "high",
      "dueDate": "2026-02-10T10:00",
      "tags": ["follow-up", "partnership"]
    }
    """
}

protocol StructuringProvider {
    func structure(text: String) async throws -> StructuredDraft
}

final class StructuringService {
    private let provider: StructuringProvider

    init(providerKind: StructuringProviderKind = StructuringService.defaultProviderKind()) {
        provider = StructuringProviderFactory.make(providerKind)
    }

    init(provider: StructuringProvider) {
        self.provider = provider
    }

    func structure(text: String) async throws -> StructuredDraft {
        var draft = try await provider.structure(text: text)
        if draft.dueDate == nil {
            draft.dueDate = DueDateParser.detect(in: text)
        }
        return draft
    }

    static func defaultProviderKind() -> StructuringProviderKind {
        if let rawValue = UserDefaults.standard.string(forKey: "structuringProvider"),
           let kind = StructuringProviderKind(rawValue: rawValue) {
            return kind
        }
        return .mock
    }
}

enum StructuringProviderFactory {
    static func make(_ kind: StructuringProviderKind) -> StructuringProvider {
        switch kind {
        case .mock:
            return MockStructuringProvider()
        case .openAI:
            guard let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey"),
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UnavailableStructuringProvider(name: "OpenAI API key missing")
            }
            let model = UserDefaults.standard.string(forKey: "openAIModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = (model?.isEmpty == false) ? model! : "gpt-5.2"
            return OpenAIStructuringProvider(apiKey: apiKey, model: resolvedModel)
        case .doubao:
            guard let apiToken = UserDefaults.standard.string(forKey: "doubaoAPIToken"),
                  !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UnavailableStructuringProvider(name: "Doubao API token missing")
            }
            let model = UserDefaults.standard.string(forKey: "doubaoModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = (model?.isEmpty == false) ? model! : "doubao-seed-1-6-lite-251015"
            return DoubaoStructuringProvider(apiToken: apiToken, model: resolvedModel)
        }
    }
}

struct MockStructuringProvider: StructuringProvider {
    func structure(text: String) async throws -> StructuredDraft {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedText.isEmpty ? "Untitled" : String(trimmedText.prefix(40))
        let type = inferredType(from: trimmedText)
        let priority = inferredPriority(from: trimmedText)
        let tags = inferredTags(from: trimmedText)

        return StructuredDraft(
            type: type,
            title: title,
            details: trimmedText,
            priority: priority,
            dueDate: nil,
            tags: tags
        )
    }

    private func inferredType(from text: String) -> ItemType {
        let lowercased = text.lowercased()
        if lowercased.contains("idea") {
            return .idea
        }
        if lowercased.contains("todo") || lowercased.contains("task") {
            return .task
        }
        return .note
    }

    private func inferredPriority(from text: String) -> ItemPriority {
        let lowercased = text.lowercased()
        if lowercased.contains("urgent") || lowercased.contains("asap") {
            return .high
        }
        if lowercased.contains("low priority") {
            return .low
        }
        return .normal
    }

    private func inferredTags(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .filter { $0.hasPrefix("#") }
            .map { $0.dropFirst() }
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}

struct UnavailableStructuringProvider: StructuringProvider {
    let name: String

    func structure(text: String) async throws -> StructuredDraft {
        throw StructuringError.unavailable(name)
    }
}

struct OpenAIStructuringProvider: StructuringProvider {
    let apiKey: String
    let model: String
    let endpoint: URL

    init(apiKey: String, model: String, endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    func structure(text: String) async throws -> StructuredDraft {
        let prompt = StructuringPrompt.buildPrompt(for: text)
        let requestBody = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: "You return JSON only."),
                ChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StructuringError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StructuringError.invalidResponse("OpenAI error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else {
            throw StructuringError.invalidResponse("OpenAI response missing content")
        }

        let jsonString = sanitizeJSON(content)
        return try StructuringParser.decodeDraft(from: jsonString)
    }

    private func sanitizeJSON(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }
        return trimmed
    }
}

struct DoubaoStructuringProvider: StructuringProvider {
    let apiToken: String
    let model: String?
    let endpoint: URL

    init(apiToken: String, model: String?, endpoint: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!) {
        self.apiToken = apiToken
        self.model = model
        self.endpoint = endpoint
    }

    func structure(text: String) async throws -> StructuredDraft {
        let prompt = StructuringPrompt.buildPrompt(for: text)
        let requestBody = DoubaoCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: "You return JSON only."),
                ChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 500
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StructuringError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StructuringError.invalidResponse("Doubao error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(DoubaoCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.resolvedContent else {
            throw StructuringError.invalidResponse("Doubao response missing content")
        }

        let jsonString = sanitizeJSON(content)
        return try StructuringParser.decodeDraft(from: jsonString)
    }

    private func sanitizeJSON(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }
        return trimmed
    }
}

struct OpenAIConnectivityTester {
    let apiKey: String
    let endpoint: URL

    init(apiKey: String, endpoint: URL = URL(string: "https://api.openai.com/v1/models")!) {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    func testConnection() async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StructuringError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw StructuringError.invalidResponse("OpenAI error \(httpResponse.statusCode)")
        }
    }
}

struct DoubaoConnectivityTester {
    let apiToken: String
    let endpoint: URL
    let model: String

    init(
        apiToken: String,
        model: String = "doubao-seed-1-6-lite-251015",
        endpoint: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
    ) {
        self.apiToken = apiToken
        self.endpoint = endpoint
        self.model = model
    }

    func testConnection() async throws {
        let requestBody = DoubaoCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "user", content: "Ping")
            ],
            temperature: 0.0,
            maxTokens: 1
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StructuringError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw StructuringError.invalidResponse("Doubao error \(httpResponse.statusCode)")
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Encodable, Decodable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatCompletionChoice]
}

private struct ChatCompletionChoice: Decodable {
    let message: ChatMessage
}

private struct DoubaoCompletionRequest: Encodable {
    let model: String?
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct DoubaoCompletionResponse: Decodable {
    let choices: [DoubaoChoice]
}

private struct DoubaoChoice: Decodable {
    let text: String?
    let message: ChatMessage?

    var resolvedContent: String? {
        if let message {
            return message.content
        }
        return text
    }
}
