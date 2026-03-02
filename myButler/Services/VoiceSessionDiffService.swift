import Foundation

enum VoiceSessionDiffError: Error {
    case unavailable(String)
    case invalidResponse(String)
}

protocol VoiceSessionDiffProvider {
    func summarizeTranscript(_ transcript: String) async throws -> String
    func proposeDiff(summary: String, items: [Item]) async throws -> VoiceSessionDiff
}

final class VoiceSessionDiffService {
    private let provider: VoiceSessionDiffProvider
    private let logger: ((String) -> Void)?

    init(
        providerKind: StructuringProviderKind = VoiceSessionDiffService.defaultProviderKind(),
        logger: ((String) -> Void)? = nil
    ) {
        provider = VoiceSessionDiffProviderFactory.make(providerKind)
        self.logger = logger
    }

    func proposeDiff(transcript: String, items: [Item]) async throws -> VoiceSessionDiff {
        let summary: String
        do {
            logger?("Diff summary started")
            summary = try await provider.summarizeTranscript(transcript)
            logger?("Diff summary completed (chars=\(summary.count))")
        } catch {
            throw VoiceSessionDiffError.invalidResponse("Summary step failed: \(error.localizedDescription)")
        }
        do {
            logger?("Diff proposal started")
            let enrichedSummary = VoiceSessionDiffPrompt.appendDeletionHints(to: summary, transcript: transcript)
            let diff = try await provider.proposeDiff(summary: enrichedSummary, items: items)
            logger?("Diff proposal completed")
            return diff
        } catch {
            throw VoiceSessionDiffError.invalidResponse("Diff step failed: \(error.localizedDescription)")
        }
    }

    static func defaultProviderKind() -> StructuringProviderKind {
        if let rawValue = UserDefaults.standard.string(forKey: "structuringProvider"),
           let kind = StructuringProviderKind(rawValue: rawValue) {
            return kind
        }
        return .mock
    }
}

enum VoiceSessionDiffProviderFactory {
    static func make(_ kind: StructuringProviderKind) -> VoiceSessionDiffProvider {
        switch kind {
        case .mock:
            return MockVoiceSessionDiffProvider()
        case .openAI:
            guard let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey"),
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UnavailableVoiceSessionDiffProvider(name: "OpenAI API key missing")
            }
            let model = UserDefaults.standard.string(forKey: "openAIModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = (model?.isEmpty == false) ? model! : "gpt-5.2"
            return OpenAIVoiceSessionDiffProvider(apiKey: apiKey, model: resolvedModel)
        case .doubao:
            guard let apiToken = UserDefaults.standard.string(forKey: "doubaoAPIToken"),
                  !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UnavailableVoiceSessionDiffProvider(name: "Doubao API token missing")
            }
            let model = UserDefaults.standard.string(forKey: "doubaoModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = (model?.isEmpty == false) ? model! : "doubao-seed-1-8-251228"
            return DoubaoVoiceSessionDiffProvider(apiToken: apiToken, model: resolvedModel)
        }
    }
}

struct UnavailableVoiceSessionDiffProvider: VoiceSessionDiffProvider {
    let name: String

    func summarizeTranscript(_ transcript: String) async throws -> String {
        throw VoiceSessionDiffError.unavailable(name)
    }

    func proposeDiff(summary: String, items: [Item]) async throws -> VoiceSessionDiff {
        throw VoiceSessionDiffError.unavailable(name)
    }
}

struct MockVoiceSessionDiffProvider: VoiceSessionDiffProvider {
    func summarizeTranscript(_ transcript: String) async throws -> String {
        return transcript
    }

    func proposeDiff(summary: String, items: [Item]) async throws -> VoiceSessionDiff {
        return VoiceSessionDiff()
    }
}

struct OpenAIVoiceSessionDiffProvider: VoiceSessionDiffProvider {
    let apiKey: String
    let model: String
    let endpoint: URL
    let timeout: TimeInterval

    init(
        apiKey: String,
        model: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        timeout: TimeInterval = 120
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.timeout = timeout
    }

    func summarizeTranscript(_ transcript: String) async throws -> String {
        let prompt = VoiceSessionDiffPrompt.buildSummary(transcript: transcript)
        let requestBody = VoiceSessionDiffChatRequest(
            model: model,
            messages: [
                VoiceSessionDiffChatMessage(role: "system", content: "Return summary text only."),
                VoiceSessionDiffChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 1000
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("OpenAI error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(VoiceSessionDiffChatResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else {
            throw VoiceSessionDiffError.invalidResponse("OpenAI response missing content")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func proposeDiff(summary: String, items: [Item]) async throws -> VoiceSessionDiff {
        let prompt = VoiceSessionDiffPrompt.buildDiff(summary: summary, items: items)
        let requestBody = VoiceSessionDiffChatRequest(
            model: model,
            messages: [
                VoiceSessionDiffChatMessage(role: "system", content: "Return JSON only."),
                VoiceSessionDiffChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 1500
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("OpenAI error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(VoiceSessionDiffChatResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else {
            throw VoiceSessionDiffError.invalidResponse("OpenAI response missing content")
        }
        return try VoiceSessionDiffPrompt.decodeDiff(from: content)
    }
}

struct DoubaoVoiceSessionDiffProvider: VoiceSessionDiffProvider {
    let apiToken: String
    let model: String?
    let endpoint: URL
    let timeout: TimeInterval

    init(
        apiToken: String,
        model: String?,
        endpoint: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!,
        timeout: TimeInterval = 120
    ) {
        self.apiToken = apiToken
        self.model = model
        self.endpoint = endpoint
        self.timeout = timeout
    }

    func summarizeTranscript(_ transcript: String) async throws -> String {
        let prompt = VoiceSessionDiffPrompt.buildSummary(transcript: transcript)
        let requestBody = VoiceSessionDiffDoubaoRequest(
            model: model,
            messages: [
                VoiceSessionDiffChatMessage(role: "system", content: "Return summary text only."),
                VoiceSessionDiffChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 1000
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("Doubao error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(VoiceSessionDiffDoubaoResponse.self, from: data)
        guard let content = completion.choices.first?.resolvedContent else {
            throw VoiceSessionDiffError.invalidResponse("Doubao response missing content")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func proposeDiff(summary: String, items: [Item]) async throws -> VoiceSessionDiff {
        let prompt = VoiceSessionDiffPrompt.buildDiff(summary: summary, items: items)
        let requestBody = VoiceSessionDiffDoubaoRequest(
            model: model,
            messages: [
                VoiceSessionDiffChatMessage(role: "system", content: "Return JSON only."),
                VoiceSessionDiffChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 1500
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("Doubao error \(httpResponse.statusCode): \(body)")
        }

        let completion = try JSONDecoder().decode(VoiceSessionDiffDoubaoResponse.self, from: data)
        guard let content = completion.choices.first?.resolvedContent else {
            throw VoiceSessionDiffError.invalidResponse("Doubao response missing content")
        }
        return try VoiceSessionDiffPrompt.decodeDiff(from: content)
    }
}

enum VoiceSessionDiffPrompt {
    static func buildSummary(transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Summarize the following full conversation transcript into concise key points.
        Focus on tasks, ideas, decisions, dates, user confirmations, and explicit removals or cancellations.
        Preserve important details and wording; do not invent new items.
        Output plain text only (no JSON, no markdown).

        Transcript:
        \(trimmedTranscript)
        """
    }

    static func buildDiff(summary: String, items: [Item]) -> String {
        let contextItems = items.map { VoiceSessionExistingItem(item: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let itemsJSON = (try? String(data: encoder.encode(contextItems), encoding: .utf8)) ?? "[]"
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        You are an assistant that produces a diff for updating a personal inbox.
        Use the existing items and the conversation summary to propose changes.
        Output JSON only, following this schema exactly. Do not include markdown.

        Rules:
        - Do not delete items unless the user explicitly asked to remove or cancel them.
        - Use updates when modifying existing items; reference the exact id.
        - For duplicates, create a merge entry that references a create tempId and the targetId.
        - If the user confirms a merge, delete any existing duplicate items (besides the target) and explain why in the delete reason.
        - If a new item is very similar to an existing one, do not create a separate item; add a merge entry and explain the duplication.
        - Follow the user’s decisions in the transcript (e.g., if they said “merge” or “keep as new”).
        - Every create must include a unique tempId.
        - If no changes are needed, return an object with empty arrays.

        Existing items (JSON array):
        \(itemsJSON)

        Conversation summary:
        \(trimmedSummary)

        JSON schema:
        {
          "creates": [
            {
              "tempId": "new-1",
              "type": "task|idea|note",
              "title": "…",
              "details": "…",
              "dueDate": "YYYY-MM-DDTHH:mm or null",
              "priority": "low|normal|high",
              "project": "… or null",
              "tags": ["…"]
            }
          ],
          "updates": [
            {
              "id": "existing-item-id",
              "changes": {
                "title": "…",
                "details": "…",
                "dueDate": "YYYY-MM-DDTHH:mm or null",
                "priority": "low|normal|high",
                "project": "… or null",
                "tags": ["…"]
              }
            }
          ],
          "merges": [
            {
              "sourceTempId": "new-2",
              "targetId": "existing-item-id",
              "mergeSummary": "Reason"
            }
          ],
          "deletes": [
            {
              "id": "existing-item-id",
              "reason": "Reason"
            }
          ]
        }
        """
    }

    static func appendDeletionHints(to summary: String, transcript: String) -> String {
        let hints = extractDeletionHints(from: transcript)
        guard !hints.isEmpty else { return summary }
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let hintBlock = hints.joined(separator: "\n")
        return """
        \(trimmedSummary)

        Deletion hints from transcript (treat as explicit user removals unless contradicted):
        \(hintBlock)
        """
    }

    private static func extractDeletionHints(from transcript: String) -> [String] {
        let keywords = [
            "remove",
            "delete",
            "cancel",
            "drop",
            "clear",
            "discard",
            "删除",
            "取消",
            "移除",
            "删掉",
            "去掉",
            "不要了",
            "撤销"
        ]
        let lines = transcript.split(separator: "\n")
        return lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lowercased = trimmed.lowercased()
            let hasKeyword = keywords.contains { keyword in
                lowercased.contains(keyword.lowercased()) || trimmed.contains(keyword)
            }
            guard hasKeyword else { return nil }
            return trimmed
        }
    }

    static func decodeDiff(from content: String) throws -> VoiceSessionDiff {
        let sanitized = sanitizeJSON(content)
        let data = Data(sanitized.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceSessionDiff.self, from: data)
    }

    private static func sanitizeJSON(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }
        return trimmed
    }
}

private struct VoiceSessionExistingItem: Encodable {
    let id: String
    let type: String
    let title: String
    let details: String
    let dueDate: Date?
    let priority: String
    let project: String?
    let tags: [String]

    init(item: Item) {
        id = item.id.uuidString
        type = item.type.rawValue
        title = item.title
        details = item.details
        dueDate = item.dueDate
        priority = item.priority.label.lowercased()
        project = item.project
        tags = item.tags
    }
}

private struct VoiceSessionDiffChatRequest: Encodable {
    let model: String
    let messages: [VoiceSessionDiffChatMessage]
    let temperature: Double
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct VoiceSessionDiffChatMessage: Encodable, Decodable {
    let role: String
    let content: String
}

private struct VoiceSessionDiffChatResponse: Decodable {
    let choices: [VoiceSessionDiffChatChoice]
}

private struct VoiceSessionDiffChatChoice: Decodable {
    let message: VoiceSessionDiffChatMessage
}

private struct VoiceSessionDiffDoubaoRequest: Encodable {
    let model: String?
    let messages: [VoiceSessionDiffChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct VoiceSessionDiffDoubaoResponse: Decodable {
    let choices: [VoiceSessionDiffDoubaoChoice]
}

private struct VoiceSessionDiffDoubaoChoice: Decodable {
    let text: String?
    let message: VoiceSessionDiffChatMessage?

    var resolvedContent: String? {
        if let message {
            return message.content
        }
        return text
    }
}
