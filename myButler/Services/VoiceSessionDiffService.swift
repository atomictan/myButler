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
    private let providerKind: StructuringProviderKind
    private let logger: ((String) -> Void)?
    private let summaryBypassCharLimit = 1200

    init(
        providerKind: StructuringProviderKind = VoiceSessionDiffService.defaultProviderKind(),
        logger: ((String) -> Void)? = nil
    ) {
        self.providerKind = providerKind
        provider = VoiceSessionDiffProviderFactory.make(providerKind)
        self.logger = logger
    }

    func proposeDiff(transcript: String, deletionTranscript: String, items: [Item]) async throws -> VoiceSessionDiff {
        let summary: String
        if transcript.count <= summaryBypassCharLimit {
            summary = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            logger?("Diff summary skipped (chars=\(summary.count))")
        } else {
            do {
                logger?("Diff summary started")
                summary = try await provider.summarizeTranscript(transcript)
                logger?("Diff summary completed (chars=\(summary.count))")
            } catch {
                throw VoiceSessionDiffError.invalidResponse("Summary step failed: \(error.localizedDescription)")
            }
        }
        do {
            logger?("Diff proposal started")
            let enrichedSummary = VoiceSessionDiffPrompt.appendDeletionHints(to: summary, transcript: deletionTranscript)
            let diff = try await provider.proposeDiff(summary: enrichedSummary, items: items)
            logger?("Diff proposal completed")
            let resolvedDiff = await resolveMissingDueDates(in: diff, transcript: deletionTranscript)
            return resolvedDiff
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
            let resolvedModel = (model?.isEmpty == false) ? model! : "doubao-seed-2-0-mini-260215"
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
            maxTokens: 600
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
            maxTokens: 900
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
            maxTokens: 600
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
            maxTokens: 900
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
        let referenceTimestamp = DueDateParser.referenceTimestamp()
        let timeZoneName = TimeZone.current.identifier
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
        - Today is \(referenceTimestamp) (timezone: \(timeZoneName)). Resolve relative dates against this reference.
        - If the user mentions any date or time (e.g., "next Monday", "Wednesday after next week", "tomorrow 6pm"), always set "dueDate".
        - Use ISO-8601. If time is provided, use "YYYY-MM-DDTHH:mm". If only a date is known, use "YYYY-MM-DD".
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
              "dueDate": "YYYY-MM-DDTHH:mm or YYYY-MM-DD or null",
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
                "dueDate": "YYYY-MM-DDTHH:mm or YYYY-MM-DD or null",
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

private extension VoiceSessionDiffService {
    func resolveMissingDueDates(in diff: VoiceSessionDiff, transcript: String) async -> VoiceSessionDiff {
        let resolvedCreates = await resolveDueDates(in: diff.creates, transcript: transcript)
        let resolvedUpdates = await resolveDueDates(in: diff.updates, transcript: transcript)
        return VoiceSessionDiff(
            creates: resolvedCreates,
            updates: resolvedUpdates,
            merges: diff.merges,
            deletes: diff.deletes
        )
    }

    func resolveDueDates(in creates: [VoiceSessionDiffCreate], transcript: String) async -> [VoiceSessionDiffCreate] {
        var resolved: [VoiceSessionDiffCreate] = []
        for create in creates {
            let dueDate = await resolveDueDate(
                existing: create.dueDate,
                title: create.title,
                details: create.details,
                transcript: transcript,
                itemCount: creates.count
            )
            resolved.append(
                VoiceSessionDiffCreate(
                    tempId: create.tempId,
                    type: create.type,
                    title: create.title,
                    details: create.details,
                    dueDate: dueDate,
                    priority: create.priority,
                    project: create.project,
                    tags: create.tags
                )
            )
        }
        return resolved
    }

    func resolveDueDates(in updates: [VoiceSessionDiffUpdate], transcript: String) async -> [VoiceSessionDiffUpdate] {
        var resolved: [VoiceSessionDiffUpdate] = []
        for update in updates {
            let dueDate = await resolveDueDate(
                existing: update.changes.dueDate,
                title: update.changes.title,
                details: update.changes.details,
                transcript: transcript,
                itemCount: updates.count
            )
            let changes = VoiceSessionDiffChanges(
                title: update.changes.title,
                details: update.changes.details,
                dueDate: dueDate,
                priority: update.changes.priority,
                project: update.changes.project,
                tags: update.changes.tags
            )
            resolved.append(VoiceSessionDiffUpdate(id: update.id, changes: changes))
        }
        return resolved
    }

    func resolveDueDate(existing: Date?, title: String?, details: String?, transcript: String, itemCount: Int) async -> Date? {
        let transcriptDate = extractTranscriptDueDate(
            title: title,
            details: details,
            transcript: transcript,
            itemCount: itemCount
        )
        if let existing {
            if let transcriptDate, shouldOverrideDueDate(existing: existing, candidate: transcriptDate) {
                logger?("Due date overridden from transcript")
                return transcriptDate
            }
            return existing
        }
        if let transcriptDate {
            return transcriptDate
        }
        let text = buildDueDateInput(title: title, details: details)
        guard !text.isEmpty else { return nil }
        if let localDate = DueDateParser.detect(in: text) {
            return localDate
        }
        guard providerKind != .mock else { return nil }
        let structuringService = StructuringService(providerKind: providerKind)
        do {
            let draft = try await structuringService.structure(text: text)
            return draft.dueDate
        } catch {
            logger?("Due date fallback failed: \(error.localizedDescription)")
            return nil
        }
    }

    func buildDueDateInput(title: String?, details: String?) -> String {
        let parts = [title, details]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: ". ")
    }

    func extractTranscriptDueDate(title: String?, details: String?, transcript: String, itemCount: Int) -> Date? {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else { return nil }
        let lines = cleanedTranscript.split(separator: "\n", omittingEmptySubsequences: false)
        let normalizedLines = lines.map { normalizeTranscriptLine(String($0)) }
        if itemCount == 1 {
            for line in normalizedLines {
                if let date = DueDateParser.detect(in: line) {
                    return date
                }
            }
        }
        let tokens = extractTitleTokens(title: title, details: details)
        guard !tokens.isEmpty else { return nil }
        var best: (score: Int, date: Date)?
        for line in normalizedLines {
            let lower = line.lowercased()
            let score = tokens.reduce(0) { count, token in
                lower.contains(token) ? count + 1 : count
            }
            guard score > 0, let date = DueDateParser.detect(in: line) else { continue }
            if best == nil || score > best!.score {
                best = (score, date)
            }
        }
        return best?.date
    }

    func normalizeTranscriptLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorRange = trimmed.range(of: ":") else { return trimmed }
        let prefix = trimmed[..<separatorRange.lowerBound]
        if prefix.count <= 12 {
            let start = trimmed.index(after: separatorRange.lowerBound)
            return trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    func extractTitleTokens(title: String?, details: String?) -> [String] {
        let combined = [title, details].compactMap { $0 }.joined(separator: " ")
        let separators = CharacterSet.alphanumerics.inverted
        return combined
            .lowercased()
            .components(separatedBy: separators)
            .filter { $0.count > 2 }
    }

    func shouldOverrideDueDate(existing: Date, candidate: Date) -> Bool {
        let calendar = Calendar.current
        return !calendar.isDate(existing, inSameDayAs: candidate)
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
