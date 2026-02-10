import Combine
import Foundation

final class VoiceSessionViewModel: ObservableObject {
    @Published var statusText = "Idle"
    @Published var transcript = ""
    @Published var isActive = false
    @Published var isShowingError = false
    @Published var errorMessage = ""
    @Published var inputLevel: Double = 0
    @Published var outputLevel: Double = 0
    @Published var inputChunkCount: Int = 0
    @Published var outputChunkCount: Int = 0
    @Published var lastInputPacketTime: Date?
    @Published var lastOutputPacketTime: Date?
    @Published var recentInputPacketSizes: [Int] = []
    @Published var recentOutputPacketSizes: [Int] = []

    private let store: ItemStore
    private let audioService = RealtimeAudioService()
    private var provider: RealtimeSessionProvider?
    private var asrClient: DoubaoRealtimeASRClient?
    private var eventTask: Task<Void, Never>?
    private var sessionStart: Date?
    private var latestAssistantText: String?
    private var pendingProposal: PendingProposal?
    private var lastLevelUpdate = Date.distantPast
    private var lastOutputLevelUpdate = Date.distantPast
    private var latestUserTranscript: String?
    private var asrSource: String {
        UserDefaults.standard.string(forKey: "voiceSessionASRSource") ?? "doubao"
    }

    private var useLocalTranscription: Bool {
        asrSource == "local"
    }

    init(store: ItemStore) {
        self.store = store
    }

    func startSession() {
        guard !isActive else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.statusText = "Connecting..."
            }
            do {
                print("[VoiceSession] Starting session")
                let provider = try await MainActor.run { try self.makeProvider() }
                await MainActor.run {
                    self.provider = provider
                }
                try await provider.startSession()

                let permissionGranted = await self.audioService.requestRecordPermission()
                guard permissionGranted else {
                    throw NSError(domain: "VoiceSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."])
                }
                let useLocalTranscription = await MainActor.run { self.useLocalTranscription }
                if useLocalTranscription {
                    _ = await self.audioService.requestSpeechPermission()
                } else {
                    try await MainActor.run {
                        self.asrClient = try self.makeASRClient()
                        self.asrClient?.onTranscript = { [weak self] text in
                            Task { @MainActor in
                                self?.handleRemoteTranscript(text)
                            }
                        }
                        self.asrClient?.onError = { error in
                            print("[VoiceSession][ASR] Error: \(error)")
                        }
                    }
                    try await self.asrClient?.start()
                }

                try await MainActor.run {
                    self.latestUserTranscript = nil
                    try self.audioService.startCapture(onAudio: { [weak self] data in
                        self?.handleAudioLevel(from: data)
                        Task { try? await self?.provider?.sendAudio(data) }
                        Task { try? await self?.asrClient?.sendAudio(data) }
                    }, onTranscription: useLocalTranscription ? { [weak self] text in
                        Task { @MainActor in
                            self?.handleLocalTranscript(text)
                        }
                    } : nil)
                    self.audioService.startPlayback()
                }
                let startDate = Date()
                await MainActor.run {
                    self.sessionStart = startDate
                    self.isActive = true
                    self.statusText = "Streaming"
                    self.startEventLoop(provider: provider)
                }

                let context = await MainActor.run { self.recentItemsContext() }
                if !context.isEmpty {
                    try await provider.sendText(context)
                }
                print("[VoiceSession] Session started")
            } catch {
                print("[VoiceSession] Session error: \(error.localizedDescription)")
                await MainActor.run {
                    self.handleError(error)
                }
            }
        }
    }

    func stopSession() {
        guard isActive else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.audioService.stopCapture()
                self.audioService.stopPlayback()
            }
            await self.provider?.stopSession()
            await self.asrClient?.stop()
            await MainActor.run {
                self.provider = nil
                self.asrClient = nil
                self.eventTask?.cancel()
                self.eventTask = nil
                self.isActive = false
                self.statusText = "Idle"
                self.persistSummaryIfNeeded()
                self.audioService.stopAll()
            }
        }
    }

    func updateSpeakerRouting(useSpeaker: Bool) {
        guard isActive else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.audioService.updateOutputRouting(useSpeaker: useSpeaker)
            } catch {
                self.handleError(error)
            }
        }
    }

    private func startEventLoop(provider: RealtimeSessionProvider) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in provider.events {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: RealtimeSessionEvent) {
        switch event {
        case .connected:
            Task { @MainActor in
                self.statusText = "Streaming"
            }
        case .disconnected:
            Task { @MainActor in
                self.statusText = "Idle"
            }
        case .audio(let data):
            Task { @MainActor in
                self.audioService.playAudioChunk(data)
                self.handleOutputLevel(from: data)
            }
        case .text(let text):
            Task { @MainActor in
                self.latestAssistantText = text
                self.transcript = self.appendLine(self.transcript, prefix: "Assistant", text: text)
            }
        case .payload(let payload):
            Task { @MainActor in
                self.handlePayload(payload)
            }
        case .error(let message):
            if message.contains("CancellationError") {
                return
            }
            Task { @MainActor in
                self.errorMessage = message
                self.isShowingError = true
                self.statusText = "Error"
            }
        }
    }

    private func handlePayload(_ payload: [String: Any]) {
        print("[VoiceSession][Payload] \(payload)")
        if let text = extractASRText(from: payload) {
            print("[VoiceSession][User] \(text)")
            transcript = setLine(transcript, prefix: "You", text: text)
            handleUserVoiceCommand(text)
            return
        }
        if let header = payload["header"] as? [String: Any],
           let name = header["name"] as? String {
            if name == "user_speech_recognition" {
                if let text = transcriptValue(from: payload, key: "transcript") {
                    print("[VoiceSession][User] \(text)")
                    transcript = setLine(transcript, prefix: "You", text: text)
                    handleUserVoiceCommand(text)
                }
                return
            }
            if name == "user_speech_end" {
                if let text = transcriptValue(from: payload, key: "final_transcript") {
                    print("[VoiceSession][User] \(text)")
                    transcript = setLine(transcript, prefix: "You", text: text)
                    handleUserVoiceCommand(text)
                }
                return
            }
        }
        if let text = payload["asr_text"] as? String {
            print("[VoiceSession][User] \(text)")
            transcript = setLine(transcript, prefix: "You", text: text)
            handleUserVoiceCommand(text)
            return
        }

        if let text = payload["text"] as? String, payload["content"] == nil {
            print("[VoiceSession][User] \(text)")
            transcript = setLine(transcript, prefix: "You", text: text)
            handleUserVoiceCommand(text)
        }
    }

    private func transcriptValue(from payload: [String: Any], key: String) -> String? {
        if let text = payload[key] as? String {
            return text
        }
        if let data = payload["data"] as? [String: Any], let text = data[key] as? String {
            return text
        }
        if let nestedPayload = payload["payload"] as? [String: Any] {
            if let text = nestedPayload[key] as? String {
                return text
            }
            if let data = nestedPayload["data"] as? [String: Any], let text = data[key] as? String {
                return text
            }
        }
        return nil
    }

    private func extractASRText(from payload: [String: Any]) -> String? {
        if let extra = payload["extra"] as? [String: Any] {
            if let origin = extra["origin_text"] as? String, !origin.isEmpty {
                return origin
            }
            if let soft = extra["soft_finish_paralinguistic"] as? [String: Any],
               let text = soft["asr_text"] as? String,
               !text.isEmpty {
                return text
            }
        }
        if let results = payload["results"] as? [[String: Any]] {
            for result in results {
                if let text = result["text"] as? String, !text.isEmpty {
                    return text
                }
                if let alternatives = result["alternatives"] as? [[String: Any]] {
                    for alt in alternatives {
                        if let text = alt["text"] as? String, !text.isEmpty {
                            return text
                        }
                    }
                }
            }
        }
        return nil
    }

    private func handleLocalTranscript(_ text: String) {
        guard text != latestUserTranscript else { return }
        latestUserTranscript = text
        transcript = setLine(transcript, prefix: "You", text: text)
        handleUserVoiceCommand(text)
    }

    private func handleRemoteTranscript(_ text: String) {
        guard text != latestUserTranscript else { return }
        latestUserTranscript = text
        transcript = setLine(transcript, prefix: "You", text: text)
        handleUserVoiceCommand(text)
    }

    private func handleUserVoiceCommand(_ text: String) {
        let command = text.lowercased()

        if let expansion = parseHistoryExpansion(from: command) {
            Task { try? await sendHistoryExpansion(months: expansion) }
            return
        }

        let normalized = normalizeCommand(command)
        if pendingProposal != nil, isConfirmCommand(normalized) {
            applyPendingProposal()
            return
        }

        if pendingProposal != nil, isRejectCommand(normalized) {
            pendingProposal = nil
            transcript = appendLine(transcript, prefix: "System", text: "Proposal discarded.")
            return
        }

        if pendingProposal != nil, isModifyCommand(normalized) {
            pendingProposal = nil
            transcript = appendLine(transcript, prefix: "System", text: "Ok, waiting for updated proposal.")
        }
    }

    private func normalizeCommand(_ command: String) -> String {
        let filtered = command.filter { $0.isLetter || $0.isNumber || $0 == " " }
        return filtered.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isConfirmCommand(_ command: String) -> Bool {
        let phrases = ["confirm", "apply", "yes apply", "yes confirm"]
        return phrases.contains(command)
    }

    private func isRejectCommand(_ command: String) -> Bool {
        let phrases = ["reject", "discard", "no dont", "no dont apply"]
        return phrases.contains(command)
    }

    private func isModifyCommand(_ command: String) -> Bool {
        let phrases = ["change that", "update it"]
        return phrases.contains(command)
    }

    private func handleAssistantText(_ text: String) {
        let (cleaned, proposal) = extractProposal(from: text)
        if let proposal {
            pendingProposal = proposal
        }
        print("[VoiceSession][Assistant] \(cleaned)")
        transcript = appendLine(transcript, prefix: "Assistant", text: cleaned)
        latestAssistantText = cleaned
    }

    private func parseHistoryExpansion(from command: String) -> Int? {
        if command.contains("all history") || command.contains("entire history") {
            return 120
        }
        if let months = extractNumber(from: command, keyword: "month") {
            return months
        }
        if let years = extractNumber(from: command, keyword: "year") {
            return years * 12
        }
        return nil
    }

    private func extractNumber(from command: String, keyword: String) -> Int? {
        guard let range = command.range(of: keyword) else { return nil }
        let prefix = command[..<range.lowerBound]
        let digits = prefix.split(separator: " ").last ?? ""
        return Int(digits)
    }

    private func sendHistoryExpansion(months: Int) async throws {
        let context = await MainActor.run { self.historyContext(months: months) }
        guard let provider else { return }
        if !context.isEmpty {
            try await provider.sendText(context)
            await MainActor.run {
                self.transcript = self.appendLine(self.transcript, prefix: "System", text: "Shared \(months)-month history.")
            }
        }
    }

    private func recentItemsContext() -> String {
        let cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let items = store.items.filter { $0.createdAt >= cutoff }
        guard !items.isEmpty else { return "" }
        return formatContext(items: items, title: "Context items (last 30 days):")
    }

    private func historyContext(months: Int) -> String {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        let items = store.items.filter { $0.createdAt >= cutoff }
        guard !items.isEmpty else { return "" }
        return formatContext(items: items, title: "Context items (last \(months) months):")
    }

    private func formatContext(items: [Item], title: String) -> String {
        let lines = items.map { item in
            let dueDate = item.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none"
            let project = item.project?.isEmpty == false ? item.project! : "none"
            let tags = item.tags.isEmpty ? "none" : item.tags.joined(separator: ", ")
            return "- [\(item.type.rawValue)] \(item.title) (project: \(project), tags: \(tags), due: \(dueDate))"
        }
        return title + "\n" + lines.joined(separator: "\n")
    }

    private func persistSummaryIfNeeded() {
        guard let summary = latestAssistantText, !summary.isEmpty else { return }
        let end = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let startText = sessionStart.map { formatter.string(from: $0) } ?? formatter.string(from: end)
        let endText = formatter.string(from: end)
        let title = "Discussion with Doubao \(startText)–\(endText)"
        store.addItem(type: .note, title: title, details: summary, rawText: summary)
        latestAssistantText = nil
        sessionStart = nil
    }

    private func makeProvider() throws -> RealtimeSessionProvider {
        let defaults = UserDefaults.standard
        let appId = defaults.string(forKey: "doubaoRealtimeAppId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessKey = defaults.string(forKey: "doubaoRealtimeAccessKey")?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let appId, !appId.isEmpty, let accessKey, !accessKey.isEmpty else {
            throw NSError(domain: "VoiceSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set Doubao realtime App ID and Access Key in Settings."])
        }

        let connectConfig = DoubaoRealtimeConfig(
            baseURL: URL(string: "wss://openspeech.bytedance.com/api/v3/realtime/dialogue")!,
            headers: [
                "X-Api-App-ID": appId,
                "X-Api-Access-Key": accessKey,
                "X-Api-Resource-Id": "volc.speech.dialog",
                "X-Api-App-Key": "DOUBAO_REALTIME_APP_KEY",
                "X-Api-Connect-Id": UUID().uuidString
            ]
        )

        let request: [String: Any] = [
            "asr": [
                "enable": true,
                "result_type": "text",
                "audio_config": [
                    "channel": 1,
                    "format": "pcm",
                    "sample_rate": 16_000
                ],
                "extra": ["end_smooth_window_ms": 1500]
            ],
            "tts": [
                "speaker": "zh_male_yunzhou_jupiter_bigtts",
                "audio_config": [
                    "channel": 1,
                    "format": "pcm",
                    "sample_rate": 24000
                ]
            ],
            "dialog": [
                "bot_name": "Assistant",
                "system_role": systemPrompt(),
                "speaking_style": "Speak clearly in English.",
                "extra": [
                    "strict_audit": false,
                    "audit_response": "",
                    "recv_timeout": 10,
                    "input_mod": "audio"
                ]
            ]
        ]

        let configuration = DoubaoRealtimeSessionConfiguration(
            connectConfig: connectConfig,
            startSessionRequest: request
        )

        return DoubaoRealtimeProvider(configuration: configuration)
    }

    private func makeASRClient() throws -> DoubaoRealtimeASRClient {
        let defaults = UserDefaults.standard
        let appId = defaults.string(forKey: "doubaoRealtimeAppId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessKey = defaults.string(forKey: "doubaoRealtimeAccessKey")?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let appId, !appId.isEmpty, let accessKey, !accessKey.isEmpty else {
            throw NSError(domain: "VoiceSession", code: 4, userInfo: [NSLocalizedDescriptionKey: "Set Doubao realtime App ID and Access Key in Settings to enable ASR transcript."])
        }

        return DoubaoRealtimeASRClient(apiKey: appId, apiSecret: accessKey)
    }

    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
        statusText = "Error"
        isActive = false
    }

    private func handleAudioLevel(from data: Data) {
        let level = Self.computeInt16Level(from: data)
        Task { @MainActor [weak self] in
            self?.updateInputLevel(level, byteCount: data.count)
        }
    }

    private static func computeInt16Level(from data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        let maxSample = data.withUnsafeBytes { rawBuffer -> Int16 in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            let sampleCount = rawBuffer.count / MemoryLayout<Int16>.size
            let samples = baseAddress.assumingMemoryBound(to: Int16.self)
            var maxValue: Int16 = 0
            for index in 0..<sampleCount {
                let value = samples[index]
                let absValue = value == Int16.min ? Int16.max : abs(value)
                if absValue > maxValue {
                    maxValue = absValue
                }
            }
            return maxValue
        }
        return Double(maxSample) / Double(Int16.max)
    }

    @MainActor
    private func updateInputLevel(_ level: Double, byteCount: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelUpdate) > 0.1 else { return }
        lastLevelUpdate = now
        inputLevel = min(max(level, 0), 1)
        inputChunkCount += 1
        lastInputPacketTime = now
        recentInputPacketSizes = Self.appendPacketSize(recentInputPacketSizes, byteCount)
    }

    private func handleOutputLevel(from data: Data) {
        let level = Self.computeFloat32Level(from: data)
        Task { @MainActor [weak self] in
            self?.updateOutputLevel(level, byteCount: data.count)
        }
    }

    @MainActor
    private func updateOutputLevel(_ level: Double, byteCount: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastOutputLevelUpdate) > 0.1 else { return }
        lastOutputLevelUpdate = now
        outputLevel = min(max(level, 0), 1)
        outputChunkCount += 1
        lastOutputPacketTime = now
        recentOutputPacketSizes = Self.appendPacketSize(recentOutputPacketSizes, byteCount)
    }

    private static func computeFloat32Level(from data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        let maxSample = data.withUnsafeBytes { rawBuffer -> Float in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            let sampleCount = rawBuffer.count / MemoryLayout<Float>.size
            let samples = baseAddress.assumingMemoryBound(to: Float.self)
            var maxValue: Float = 0
            for index in 0..<sampleCount {
                let value = abs(samples[index])
                if value > maxValue {
                    maxValue = value
                }
            }
            return maxValue
        }
        return Double(min(maxSample, 1))
    }

    private static func appendPacketSize(_ list: [Int], _ value: Int) -> [Int] {
        var updated = list
        updated.append(value)
        if updated.count > 5 {
            updated.removeFirst(updated.count - 5)
        }
        return updated
    }

    private func systemPrompt() -> String {
        """
        You are a helpful voice assistant for a personal organizer app.
        Speak in short, clear sentences.
        When proposing item changes, explicitly say what you will create or update and ask the user to say "confirm" to apply or "reject" to discard.
        If you propose changes, include a JSON object on a new line prefixed with "PROPOSAL_JSON:" using this schema:
        {"action":"create|update","targetTitle":"<existing title>","type":"task|idea|note","title":"...","details":"...","priority":"low|normal|high","dueDate":"YYYY-MM-DD or null","project":"...","tags":["..."]}
        For updates, include only the fields you want to change and set targetTitle.
        When the user asks for more history (e.g., "last 6 months"), wait for additional context before continuing.
        """
    }

    private func appendLine(_ base: String, prefix: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        let line = "\(prefix): \(trimmed)"
        if base.isEmpty {
            return line
        }
        let lines = base.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last, last.starts(with: "\(prefix):") {
            let updatedLast = last + " " + trimmed
            let newLines = lines.dropLast() + [Substring(updatedLast)]
            return newLines.joined(separator: "\n")
        }
        return base + "\n" + line
    }

    private func setLine(_ base: String, prefix: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        let line = "\(prefix): \(trimmed)"
        guard !base.isEmpty else { return line }
        let lines = base.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last, last.starts(with: "\(prefix):") {
            let newLines = lines.dropLast() + [Substring(line)]
            return newLines.joined(separator: "\n")
        }
        return base + "\n" + line
    }

    private func extractProposal(from text: String) -> (String, PendingProposal?) {
        guard let markerRange = text.range(of: "PROPOSAL_JSON:") else {
            return (text, nil)
        }

        let prefix = text[..<markerRange.lowerBound]
        let suffix = text[markerRange.upperBound...]
        guard let startIndex = suffix.firstIndex(of: "{") else {
            return (String(prefix).trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        guard let endIndex = suffix.lastIndex(of: "}") else {
            return (String(prefix).trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        let jsonString = suffix[startIndex...endIndex]
        let cleanedText = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
        let proposal = parseProposal(from: String(jsonString))
        return (cleanedText, proposal)
    }

    private func parseProposal(from json: String) -> PendingProposal? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any],
              let action = dict["action"] as? String else {
            return nil
        }

        let type = ItemType(rawValue: (dict["type"] as? String) ?? "note") ?? .note
        let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (dict["details"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let priority = ItemPriority(rawValue: priorityValue(from: dict["priority"])) ?? .normal
        let dueDate = parseDueDate(from: dict["dueDate"])
        let project = (dict["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (dict["tags"] as? [String]) ?? []

        if action == "create" {
            guard let resolvedTitle = title, let resolvedDetails = details else { return nil }
            let draft = DraftItem(
                type: type,
                title: resolvedTitle,
                details: resolvedDetails,
                rawText: resolvedDetails,
                priority: priority,
                dueDate: dueDate,
                tags: tags,
                project: project
            )
            return PendingProposal(action: .create(draft))
        }

        if action == "update" {
            guard let targetTitle = dict["targetTitle"] as? String else { return nil }
            guard let targetItem = store.items.first(where: { $0.title.caseInsensitiveCompare(targetTitle) == .orderedSame }) else {
                return nil
            }
            let priority: ItemPriority?
            if dict["priority"] != nil {
                priority = ItemPriority(rawValue: priorityValue(from: dict["priority"]))
            } else {
                priority = nil
            }
            let update = DraftUpdate(
                title: title,
                details: details,
                rawText: details,
                priority: priority,
                dueDate: dueDate,
                tags: dict["tags"] as? [String],
                project: project
            )
            return PendingProposal(action: .update(targetItem.id, update))
        }

        return nil
    }

    private func priorityValue(from value: Any?) -> Int {
        if let value = value as? String {
            switch value.lowercased() {
            case "low": return ItemPriority.low.rawValue
            case "high": return ItemPriority.high.rawValue
            default: return ItemPriority.normal.rawValue
            }
        }
        if let value = value as? Int {
            return value
        }
        return ItemPriority.normal.rawValue
    }

    private func parseDueDate(from value: Any?) -> Date? {
        guard let dateString = value as? String, !dateString.isEmpty else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
    }

    private func applyPendingProposal() {
        guard let pendingProposal else {
            transcript = appendLine(transcript, prefix: "System", text: "No pending proposal to apply.")
            return
        }
        switch pendingProposal.action {
        case .create(let draft):
            store.addItem(
                type: draft.type,
                title: draft.title,
                details: draft.details,
                rawText: draft.rawText,
                priority: draft.priority,
                dueDate: draft.dueDate,
                tags: draft.tags,
                project: draft.project
            )
        case .update(let id, let update):
            store.updateItem(id: id) { item in
                if let title = update.title { item.title = title }
                if let details = update.details { item.details = details }
                if let rawText = update.rawText { item.rawText = rawText }
                if let priority = update.priority { item.priority = priority }
                if let dueDate = update.dueDate { item.dueDate = dueDate }
                if let tags = update.tags { item.tags = tags }
                if let project = update.project { item.project = project }
            }
        }
        transcript = appendLine(transcript, prefix: "System", text: "Applied proposal.")
        self.pendingProposal = nil
    }
}

private struct PendingProposal {
    enum Action {
        case create(DraftItem)
        case update(UUID, DraftUpdate)
    }

    let action: Action
}

private struct DraftItem {
    let type: ItemType
    let title: String
    let details: String
    let rawText: String
    let priority: ItemPriority
    let dueDate: Date?
    let tags: [String]
    let project: String?
}

private struct DraftUpdate {
    let title: String?
    let details: String?
    let rawText: String?
    let priority: ItemPriority?
    let dueDate: Date?
    let tags: [String]?
    let project: String?
}
