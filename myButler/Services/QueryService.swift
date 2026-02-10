import Foundation

enum QueryError: Error {
    case unavailable(String)
    case invalidResponse(String)
}

protocol QueryProvider {
    func summarize(query: String, items: [Item]) async throws -> String
}

struct QueryService {
    func summarize(query: String, items: [Item]) async throws -> String {
        let provider = QueryProviderFactory.provider()
        return try await provider.summarize(query: query, items: items)
    }
}

struct QueryProviderFactory {
    static func provider() -> QueryProvider {
        let providerKind = StructuringProviderKind(
            rawValue: UserDefaults.standard.string(forKey: "structuringProvider") ?? "mock"
        ) ?? .mock

        switch providerKind {
        case .mock:
            return MockQueryProvider()
        case .openAI:
            let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = UserDefaults.standard.string(forKey: "openAIModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let apiKey, !apiKey.isEmpty else {
                return UnavailableQueryProvider(name: "OpenAI API key not configured")
            }
            let resolvedModel = (model?.isEmpty == false) ? model! : "gpt-5.2"
            return OpenAIQueryProvider(apiKey: apiKey, model: resolvedModel)
        case .doubao:
            let apiToken = UserDefaults.standard.string(forKey: "doubaoAPIToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = UserDefaults.standard.string(forKey: "doubaoModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let apiToken, !apiToken.isEmpty else {
                return UnavailableQueryProvider(name: "Doubao API token not configured")
            }
            let resolvedModel = (model?.isEmpty == false) ? model! : "doubao-seed-1-6-lite-251015"
            return DoubaoQueryProvider(apiToken: apiToken, model: resolvedModel)
        }
    }
}

struct QueryPrompt {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func buildPrompt(query: String, items: [Item]) -> String {
        let limitedItems = items.prefix(20)
        let renderedItems = limitedItems.map { item in
            let dueDateText = item.dueDate.map { dateFormatter.string(from: $0) } ?? "none"
            let projectText = item.project?.isEmpty == false ? item.project! : "none"
            let tagsText = item.tags.isEmpty ? "none" : item.tags.joined(separator: ", ")
            let details = item.details.isEmpty ? "(no details)" : item.details
            let snippet = details.count > 160 ? String(details.prefix(160)) + "…" : details
            return "- [\(item.type.rawValue)] \(item.title) — \(snippet) (priority: \(item.priority.label), due: \(dueDateText), project: \(projectText), tags: \(tagsText))"
        }

        return """
        You are a helpful personal assistant. Answer the user's question using only the items provided.
        If the items do not contain enough information, say so.
        Keep the response concise (3-6 sentences max).

        User question:
        \(query)

        Items:
        \(renderedItems.joined(separator: "\n"))
        """
    }
}

struct MockQueryProvider: QueryProvider {
    func summarize(query: String, items: [Item]) async throws -> String {
        if items.isEmpty {
            return "No items matched your query."
        }

        let titles = items.prefix(3).map { $0.title }.joined(separator: ", ")
        let suffix = items.count > 3 ? " and \(items.count - 3) more" : ""
        return "Found \(items.count) matching items. Top matches: \(titles)\(suffix)."
    }
}

struct UnavailableQueryProvider: QueryProvider {
    let name: String

    func summarize(query: String, items: [Item]) async throws -> String {
        throw QueryError.unavailable(name)
    }
}

struct OpenAIQueryProvider: QueryProvider {
    let apiKey: String
    let model: String
    let endpoint: URL

    init(apiKey: String, model: String, endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    func summarize(query: String, items: [Item]) async throws -> String {
        let prompt = QueryPrompt.buildPrompt(query: query, items: items)
        let requestBody = QueryChatCompletionRequest(
            model: model,
            messages: [
                QueryChatMessage(role: "system", content: "You answer in plain text."),
                QueryChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.3
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QueryError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QueryError.invalidResponse("OpenAI error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(QueryChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else {
            throw QueryError.invalidResponse("OpenAI response missing content")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DoubaoQueryProvider: QueryProvider {
    let apiToken: String
    let model: String
    let endpoint: URL

    init(apiToken: String, model: String, endpoint: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!) {
        self.apiToken = apiToken
        self.model = model
        self.endpoint = endpoint
    }

    func summarize(query: String, items: [Item]) async throws -> String {
        let prompt = QueryPrompt.buildPrompt(query: query, items: items)
        let requestBody = QueryDoubaoCompletionRequest(
            model: model,
            messages: [
                QueryChatMessage(role: "system", content: "You answer in plain text."),
                QueryChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.3,
            maxTokens: 500
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QueryError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QueryError.invalidResponse("Doubao error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(QueryDoubaoCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.resolvedContent else {
            throw QueryError.invalidResponse("Doubao response missing content")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct QueryChatCompletionRequest: Encodable {
    let model: String
    let messages: [QueryChatMessage]
    let temperature: Double
}

private struct QueryChatMessage: Encodable, Decodable {
    let role: String
    let content: String
}

private struct QueryChatCompletionResponse: Decodable {
    let choices: [QueryChatCompletionChoice]
}

private struct QueryChatCompletionChoice: Decodable {
    let message: QueryChatMessage
}

private struct QueryDoubaoCompletionRequest: Encodable {
    let model: String
    let messages: [QueryChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct QueryDoubaoCompletionResponse: Decodable {
    let choices: [QueryDoubaoChoice]
}

private struct QueryDoubaoChoice: Decodable {
    let text: String?
    let message: QueryChatMessage?

    var resolvedContent: String? {
        if let message {
            return message.content
        }
        return text
    }
}
