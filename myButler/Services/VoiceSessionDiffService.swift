import Foundation

private final class SessionTaskMetricsDelegate: NSObject, URLSessionTaskDelegate {
    private(set) var metrics: URLSessionTaskMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }
}

private struct SessionRequestResult {
    let data: Data
    let response: URLResponse
}

private enum SessionMetricsLogger {
    static func perform(request: URLRequest, logger: ((String) -> Void)?) async throws -> SessionRequestResult {
        let delegate = SessionTaskMetricsDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        log(metrics: delegate.metrics, logger: logger)
        return SessionRequestResult(data: data, response: response)
    }

    static func log(metrics: URLSessionTaskMetrics?, logger: ((String) -> Void)?) {
        guard let metrics else {
            logger?("HTTP metrics unavailable")
            return
        }
        logger?("HTTP metrics collected (redirects=\(metrics.redirectCount), transactions=\(metrics.transactionMetrics.count), duration=\(format(metrics.taskInterval.duration)))")
        for (index, transaction) in metrics.transactionMetrics.enumerated() {
            var parts: [String] = []
            if let requestStart = transaction.fetchStartDate {
                if let domainEnd = transaction.domainLookupEndDate {
                    let domainStart = transaction.domainLookupStartDate ?? requestStart
                    parts.append("dns=\(format(domainEnd.timeIntervalSince(domainStart)))")
                }
                if let connectEnd = transaction.connectEndDate {
                    let connectStart = transaction.connectStartDate ?? requestStart
                    parts.append("connect=\(format(connectEnd.timeIntervalSince(connectStart)))")
                }
                if let secureEnd = transaction.secureConnectionEndDate {
                    let secureStart = transaction.secureConnectionStartDate ?? requestStart
                    parts.append("tls=\(format(secureEnd.timeIntervalSince(secureStart)))")
                }
                if let requestEnd = transaction.requestEndDate {
                    parts.append("request=\(format(requestEnd.timeIntervalSince(requestStart)))")
                }
                if let responseStart = transaction.responseStartDate,
                   let requestEnd = transaction.requestEndDate {
                    parts.append("ttfb=\(format(responseStart.timeIntervalSince(requestEnd)))")
                }
                if let responseEnd = transaction.responseEndDate,
                   let responseStart = transaction.responseStartDate {
                    parts.append("download=\(format(responseEnd.timeIntervalSince(responseStart)))")
                }
            }
            let protocolName = transaction.networkProtocolName ?? "unknown"
            let proxy = transaction.isProxyConnection ? "yes" : "no"
            let reused = transaction.isReusedConnection ? "yes" : "no"
            logger?("HTTP metrics tx\(index + 1) (protocol=\(protocolName), reused=\(reused), proxy=\(proxy)): \(parts.joined(separator: ", "))")
        }
    }

    static func format(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }
}

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
    private let summaryBypassCharLimit = 100000

    init(
        providerKind: StructuringProviderKind = VoiceSessionDiffService.defaultProviderKind(),
        logger: ((String) -> Void)? = nil
    ) {
        self.providerKind = providerKind
        self.logger = logger
        provider = VoiceSessionDiffProviderFactory.make(providerKind, logger: logger)
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
            logger?("Diff proposal payload ready (provider=\(providerKind.rawValue), summaryChars=\(enrichedSummary.count), summaryBytes=\(utf8Length(enrichedSummary)), items=\(items.count))")
            let diff = try await provider.proposeDiff(summary: enrichedSummary, items: items)
            logger?("Diff proposal completed")
            let dueDateResolutionStart = Date()
            let resolvedDiff = await resolveMissingDueDates(in: diff, transcript: deletionTranscript)
            logger?(String(format: "Diff due-date resolution completed in %.2fs", Date().timeIntervalSince(dueDateResolutionStart)))
            return normalizeLikelyRouteUpdates(in: resolvedDiff, items: items)
        } catch {
            throw VoiceSessionDiffError.invalidResponse("Diff step failed: \(error.localizedDescription)")
        }
    }

    private func utf8Length(_ string: String) -> Int {
        string.lengthOfBytes(using: .utf8)
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
    static func make(_ kind: StructuringProviderKind, logger: ((String) -> Void)? = nil) -> VoiceSessionDiffProvider {
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
            return OpenAIVoiceSessionDiffProvider(apiKey: apiKey, model: resolvedModel, logger: logger)
        case .doubao:
            guard let apiToken = UserDefaults.standard.string(forKey: "doubaoAPIToken"),
                  !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UnavailableVoiceSessionDiffProvider(name: "Doubao API token missing")
            }
            let diffModel = UserDefaults.standard.string(forKey: "doubaoDiffModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel: String
            if let diffModel, !diffModel.isEmpty {
                resolvedModel = diffModel
            } else {
                resolvedModel = "doubao-seed-2-0-mini-260215"
            }
            return DoubaoVoiceSessionDiffProvider(apiToken: apiToken, model: resolvedModel, logger: logger)
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

private func decodeDiffContent(_ content: String, logger: ((String) -> Void)?) throws -> VoiceSessionDiff {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
        return try VoiceSessionDiffPrompt.decodeDiff(from: trimmed)
    } catch {
        let snippet = String(trimmed.prefix(1200)).replacingOccurrences(of: "\n", with: "\\n")
        logger?("Diff JSON parse failed: \(error.localizedDescription)")
        logger?("Diff raw content snippet: \(snippet)")
        throw error
    }
}

struct OpenAIVoiceSessionDiffProvider: VoiceSessionDiffProvider {
    let apiKey: String
    let model: String
    let endpoint: URL
    let timeout: TimeInterval
    let logger: ((String) -> Void)?

    init(
        apiKey: String,
        model: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        timeout: TimeInterval = 120,
        logger: ((String) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.timeout = timeout
        self.logger = logger
    }

    func summarizeTranscript(_ transcript: String) async throws -> String {
        let prompt = VoiceSessionDiffPrompt.buildSummary(transcript: transcript)
        logger?("OpenAI summary request prepared (model=\(model), promptChars=\(prompt.count), promptBytes=\(prompt.lengthOfBytes(using: .utf8)))")
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
        let encodeStart = Date()
        let requestData = try JSONEncoder().encode(requestBody)
        logger?(String(format: "OpenAI summary request encoded in %.2fs (bodyBytes=%d)", Date().timeIntervalSince(encodeStart), requestData.count))
        request.httpBody = requestData

        let networkStart = Date()
        let result = try await SessionMetricsLogger.perform(request: request, logger: logger)
        let data = result.data
        let response = result.response
        logger?(String(format: "OpenAI summary HTTP completed in %.2fs (responseBytes=%d)", Date().timeIntervalSince(networkStart), data.count))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("OpenAI error \(httpResponse.statusCode): \(body)")
        }

        let decodeStart = Date()
        let completion = try JSONDecoder().decode(VoiceSessionDiffChatResponse.self, from: data)
        logger?(String(format: "OpenAI summary response decoded in %.2fs", Date().timeIntervalSince(decodeStart)))
        guard let content = completion.choices.first?.message.content else {
            throw VoiceSessionDiffError.invalidResponse("OpenAI response missing content")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        logger?("OpenAI summary content extracted (chars=\(trimmed.count), bytes=\(trimmed.lengthOfBytes(using: .utf8)))")
        return trimmed
    }

    func proposeDiff(summary: String, items: [Item]) async throws -> VoiceSessionDiff {
        let prompt = VoiceSessionDiffPrompt.buildDiff(summary: summary, items: items)
        logger?("OpenAI diff request prepared (model=\(model), promptChars=\(prompt.count), promptBytes=\(prompt.lengthOfBytes(using: .utf8)), items=\(items.count))")
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
        let encodeStart = Date()
        let requestData = try JSONEncoder().encode(requestBody)
        logger?(String(format: "OpenAI diff request encoded in %.2fs (bodyBytes=%d)", Date().timeIntervalSince(encodeStart), requestData.count))
        request.httpBody = requestData

        let networkStart = Date()
        let result = try await SessionMetricsLogger.perform(request: request, logger: logger)
        let data = result.data
        let response = result.response
        logger?(String(format: "OpenAI diff HTTP completed in %.2fs (responseBytes=%d)", Date().timeIntervalSince(networkStart), data.count))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("OpenAI error \(httpResponse.statusCode): \(body)")
        }

        let decodeStart = Date()
        let completion = try JSONDecoder().decode(VoiceSessionDiffChatResponse.self, from: data)
        logger?(String(format: "OpenAI diff response decoded in %.2fs", Date().timeIntervalSince(decodeStart)))
        guard let content = completion.choices.first?.message.content else {
            throw VoiceSessionDiffError.invalidResponse("OpenAI response missing content")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        logger?("OpenAI diff content extracted (chars=\(trimmed.count), bytes=\(trimmed.lengthOfBytes(using: .utf8)))")
        let parseStart = Date()
        let diff = try decodeDiffContent(trimmed, logger: logger)
        logger?(String(format: "OpenAI diff JSON parsed in %.2fs", Date().timeIntervalSince(parseStart)))
        return diff
    }
}

struct DoubaoVoiceSessionDiffProvider: VoiceSessionDiffProvider {
    let apiToken: String
    let model: String?
    let endpoint: URL
    let timeout: TimeInterval
    let logger: ((String) -> Void)?

    init(
        apiToken: String,
        model: String?,
        endpoint: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!,
        timeout: TimeInterval = 120,
        logger: ((String) -> Void)? = nil
    ) {
        self.apiToken = apiToken
        self.model = model
        self.endpoint = endpoint
        self.timeout = timeout
        self.logger = logger
    }

    func summarizeTranscript(_ transcript: String) async throws -> String {
        let prompt = VoiceSessionDiffPrompt.buildSummary(transcript: transcript)
        logger?("Doubao summary request prepared (model=\(model ?? "nil"), promptChars=\(prompt.count), promptBytes=\(prompt.lengthOfBytes(using: .utf8)))")
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
        let encodeStart = Date()
        let requestData = try JSONEncoder().encode(requestBody)
        logger?(String(format: "Doubao summary request encoded in %.2fs (bodyBytes=%d)", Date().timeIntervalSince(encodeStart), requestData.count))
        request.httpBody = requestData

        let networkStart = Date()
        let result = try await SessionMetricsLogger.perform(request: request, logger: logger)
        let data = result.data
        let response = result.response
        logger?(String(format: "Doubao summary HTTP completed in %.2fs (responseBytes=%d)", Date().timeIntervalSince(networkStart), data.count))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("Doubao error \(httpResponse.statusCode): \(body)")
        }

        let decodeStart = Date()
        let completion = try JSONDecoder().decode(VoiceSessionDiffDoubaoResponse.self, from: data)
        logger?(String(format: "Doubao summary response decoded in %.2fs", Date().timeIntervalSince(decodeStart)))
        guard let content = completion.choices.first?.resolvedContent else {
            throw VoiceSessionDiffError.invalidResponse("Doubao response missing content")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        logger?("Doubao summary content extracted (chars=\(trimmed.count), bytes=\(trimmed.lengthOfBytes(using: .utf8)))")
        return trimmed
    }

    func proposeDiff(summary: String, items: [Item]) async throws -> VoiceSessionDiff {
        let prompt = VoiceSessionDiffPrompt.buildDiff(summary: summary, items: items)
        logger?("Doubao diff request prepared (model=\(model ?? "nil"), promptChars=\(prompt.count), promptBytes=\(prompt.lengthOfBytes(using: .utf8)), items=\(items.count))")
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
        let encodeStart = Date()
        let requestData = try JSONEncoder().encode(requestBody)
        logger?(String(format: "Doubao diff request encoded in %.2fs (bodyBytes=%d)", Date().timeIntervalSince(encodeStart), requestData.count))
        request.httpBody = requestData

        let networkStart = Date()
        let result = try await SessionMetricsLogger.perform(request: request, logger: logger)
        let data = result.data
        let response = result.response
        logger?(String(format: "Doubao diff HTTP completed in %.2fs (responseBytes=%d)", Date().timeIntervalSince(networkStart), data.count))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionDiffError.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSessionDiffError.invalidResponse("Doubao error \(httpResponse.statusCode): \(body)")
        }

        let decodeStart = Date()
        let completion = try JSONDecoder().decode(VoiceSessionDiffDoubaoResponse.self, from: data)
        logger?(String(format: "Doubao diff response decoded in %.2fs", Date().timeIntervalSince(decodeStart)))
        guard let content = completion.choices.first?.resolvedContent else {
            throw VoiceSessionDiffError.invalidResponse("Doubao response missing content")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        logger?("Doubao diff content extracted (chars=\(trimmed.count), bytes=\(trimmed.lengthOfBytes(using: .utf8)))")
        let parseStart = Date()
        let diff = try decodeDiffContent(trimmed, logger: logger)
        logger?(String(format: "Doubao diff JSON parsed in %.2fs", Date().timeIntervalSince(parseStart)))
        return diff
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
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let itemsJSON = (try? String(data: encoder.encode(contextItems), encoding: .utf8)) ?? "[]"
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let similarityHints = buildSimilarityHints(summary: trimmedSummary, items: items)
        let hintsBlock = similarityHints.isEmpty ? "" : "\nPotentially similar existing items (heuristic hints from the app; verify against the transcript):\n\(similarityHints)\n"

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
        \(hintsBlock)

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

    private static func buildSimilarityHints(summary: String, items: [Item]) -> String {
        let queryTokens = significantTokens(in: summary)
        let queryRoute = travelRoute(in: summary)
        guard !queryTokens.isEmpty || queryRoute != nil else { return "" }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none

        return items.compactMap { item -> (String, Double)? in
            let itemText = "\(item.title) \(item.details)"
            let itemTokens = significantTokens(in: itemText)
            let overlapCount = queryTokens.intersection(itemTokens).count
            let containment = queryTokens.isEmpty ? 0 : Double(overlapCount) / Double(max(1, min(queryTokens.count, itemTokens.count)))
            let routeScore = travelRouteScore(queryRoute, travelRoute(in: itemText))
            let score = max(containment, routeScore)
            guard overlapCount >= 2 || score >= 0.45 || routeScore >= 0.8 else { return nil }
            let dueText = item.dueDate.map { formatter.string(from: $0) } ?? "none"
            let line = "- id: \(item.id.uuidString), title: \(item.title), due: \(dueText), tags: \(item.tags.joined(separator: ", "))"
            return (line, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(5)
        .map(\.0)
        .joined(separator: "\n")
    }

    private static func significantTokens(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "the", "to", "from", "for", "me", "my", "on", "at", "in", "of", "and",
            "please", "could", "would", "you", "add", "set", "reminder", "trip", "take", "main"
        ]
        let normalized = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
        return Set(normalized)
    }

    private static func travelRoute(in text: String) -> (from: Set<String>, to: Set<String>)? {
        let normalized = text.lowercased()
        guard let fromRange = normalized.range(of: "from "),
              let toRange = normalized.range(of: " to ", range: fromRange.upperBound..<normalized.endIndex) else {
            return nil
        }
        let fromText = normalized[fromRange.upperBound..<toRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = normalized[toRange.upperBound...]
        let delimiters = [" on ", " at ", " by ", " due ", " for "]
        let destinationText = delimiters.compactMap { delimiter in
            tail.range(of: delimiter).map { String(tail[..<$0.lowerBound]) }
        }.first ?? String(tail)
        let fromTokens = significantTokens(in: fromText)
        let toTokens = significantTokens(in: destinationText)
        guard !fromTokens.isEmpty, !toTokens.isEmpty else { return nil }
        return (fromTokens, toTokens)
    }

    private static func travelRouteScore(_ lhs: (from: Set<String>, to: Set<String>)?, _ rhs: (from: Set<String>, to: Set<String>)?) -> Double {
        guard let lhs, let rhs else { return 0 }
        let fromOverlap = Double(lhs.from.intersection(rhs.from).count) / Double(max(1, min(lhs.from.count, rhs.from.count)))
        let toOverlap = Double(lhs.to.intersection(rhs.to).count) / Double(max(1, min(lhs.to.count, rhs.to.count)))
        if fromOverlap >= 1.0 && toOverlap >= 1.0 {
            return 0.95
        }
        return (fromOverlap + toOverlap) / 2.0
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
    func normalizeLikelyRouteUpdates(in diff: VoiceSessionDiff, items: [Item]) -> VoiceSessionDiff {
        guard !diff.creates.isEmpty else { return diff }

        let updatedIds = Set(diff.updates.map(\.id))
        let mergedTargetIds = Set(diff.merges.map(\.targetId))
        var remainingCreates: [VoiceSessionDiffCreate] = []
        var normalizedUpdates = diff.updates

        for create in diff.creates {
            guard let match = bestExistingRouteMatch(for: create, items: items),
                  !updatedIds.contains(match.id.uuidString),
                  !mergedTargetIds.contains(match.id.uuidString) else {
                remainingCreates.append(create)
                continue
            }

            logger?("Route duplicate normalized into update for \(match.title)")
            normalizedUpdates.append(
                VoiceSessionDiffUpdate(
                    id: match.id.uuidString,
                    changes: VoiceSessionDiffChanges(
                        title: create.title,
                        details: create.details.isEmpty ? nil : create.details,
                        dueDate: create.dueDate,
                        priority: create.priority,
                        project: create.project,
                        tags: create.tags.isEmpty ? nil : create.tags
                    )
                )
            )
        }

        return VoiceSessionDiff(
            creates: remainingCreates,
            updates: normalizedUpdates,
            merges: diff.merges,
            deletes: diff.deletes
        )
    }

    func bestExistingRouteMatch(for create: VoiceSessionDiffCreate, items: [Item]) -> Item? {
        guard create.type == .task else { return nil }
        let createTitle = normalizedRouteText(create.title)
        let createRoute = routeComponents(in: createTitle)
        let createTags = Set(create.tags.map { $0.lowercased() })

        let candidates = items.filter { item in
            guard item.type == .task else { return false }
            let itemTitle = normalizedRouteText(item.title)
            let itemRoute = routeComponents(in: itemTitle)
            let routesMatch = {
                guard let createRoute, let itemRoute else { return false }
                return createRoute.0 == itemRoute.0 && createRoute.1 == itemRoute.1
            }()
            guard itemTitle == createTitle || routesMatch else {
                return false
            }
            if let createDueDate = create.dueDate, let itemDueDate = item.dueDate {
                let days = abs(Calendar.current.dateComponents([.day], from: createDueDate, to: itemDueDate).day ?? Int.max)
                if days > 14 {
                    return false
                }
            }
            let itemTags = Set(item.tags.map { $0.lowercased() })
            return !createTags.isDisjoint(with: itemTags) || createRoute != nil || itemTitle == createTitle
        }

        return candidates.min { lhs, rhs in
            let lhsDistance = dueDateDistance(from: create.dueDate, to: lhs.dueDate)
            let rhsDistance = dueDateDistance(from: create.dueDate, to: rhs.dueDate)
            if lhsDistance == rhsDistance {
                return lhs.createdAt > rhs.createdAt
            }
            return lhsDistance < rhsDistance
        }
    }

    func dueDateDistance(from lhs: Date?, to rhs: Date?) -> Int {
        guard let lhs, let rhs else { return Int.max / 2 }
        return abs(Calendar.current.dateComponents([.day], from: lhs, to: rhs).day ?? Int.max / 2)
    }

    func normalizedRouteText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func routeComponents(in text: String) -> (String, String)? {
        guard let fromRange = text.range(of: "from "),
              let toRange = text.range(of: " to ", range: fromRange.upperBound..<text.endIndex) else {
            return nil
        }
        let from = text[fromRange.upperBound..<toRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text[toRange.upperBound...]
        let delimiters = [" on ", " at ", " by ", " due ", " for "]
        let to = delimiters.compactMap { delimiter in
            tail.range(of: delimiter).map { String(tail[..<$0.lowerBound]) }
        }.first ?? String(tail)
        let normalizedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFrom.isEmpty, !normalizedTo.isEmpty else { return nil }
        return (normalizedFrom, normalizedTo)
    }

    struct TranscriptLine {
        let text: String
        let speaker: TranscriptSpeaker
        let index: Int
    }

    enum TranscriptSpeaker {
        case user
        case assistant
        case other
    }

    func resolveMissingDueDates(in diff: VoiceSessionDiff, transcript: String) async -> VoiceSessionDiff {
        logger?("Diff due-date resolution started (creates=\(diff.creates.count), updates=\(diff.updates.count))")
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
            let fallbackStart = Date()
            logger?("Due date fallback started (provider=\(providerKind.rawValue), textChars=\(text.count))")
            let draft = try await structuringService.structure(text: text)
            logger?(String(format: "Due date fallback completed in %.2fs (resolved=%@)", Date().timeIntervalSince(fallbackStart), draft.dueDate == nil ? "no" : "yes"))
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
        let transcriptLines = cleanedTranscript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in parseTranscriptLine(String(line), index: index) }
        let tokens = extractTitleTokens(title: title, details: details)
        var best: (score: Int, date: Date)?
        for line in transcriptLines {
            let lower = line.text.lowercased()
            let tokenScore = tokens.reduce(0) { count, token in
                lower.contains(token) ? count + 1 : count
            }
            let correctionBonus = correctionPhraseBonus(in: lower)
            let speakerBonus = line.speaker == .user ? 50 : (line.speaker == .assistant ? 10 : 0)
            let relevanceBonus = itemCount == 1 ? 5 : 0
            let relevanceScore = tokenScore * 10 + correctionBonus + speakerBonus + relevanceBonus + line.index
            let isRelevant = itemCount == 1 || tokenScore > 0 || correctionBonus > 0
            guard isRelevant, let date = DueDateParser.detect(in: line.text) else { continue }
            if best == nil || relevanceScore > best!.score {
                best = (relevanceScore, date)
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

    func parseTranscriptLine(_ line: String, index: Int) -> TranscriptLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("You:") {
            let text = normalizeTranscriptLine(trimmed)
            return TranscriptLine(text: text, speaker: .user, index: index)
        }
        if trimmed.hasPrefix("Assistant:") {
            let text = normalizeTranscriptLine(trimmed)
            return TranscriptLine(text: text, speaker: .assistant, index: index)
        }
        return TranscriptLine(text: normalizeTranscriptLine(trimmed), speaker: .other, index: index)
    }

    func correctionPhraseBonus(in text: String) -> Int {
        let correctionPhrases = [
            "please use",
            "use ",
            "change",
            "instead",
            "actually",
            "correction",
            "update",
            "no no",
            "wrong date",
            "for the date"
        ]
        return correctionPhrases.contains(where: { text.contains($0) }) ? 100 : 0
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
    let dueDate: Date?
    let priority: String
    let project: String?
    let tags: [String]

    init(item: Item) {
        id = item.id.uuidString
        type = item.type.rawValue
        title = item.title
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
