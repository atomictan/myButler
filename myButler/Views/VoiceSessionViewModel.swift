import AVFoundation
import Combine
import Foundation
import Speech

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
    @Published private(set) var latestRunLogFiles: [URL] = []
    @Published var pendingDiff: VoiceSessionDiff?
    @Published var isShowingDiffReview = false
    @Published var isShowingDiffError = false
    @Published var diffErrorMessage = ""
    @Published var canGenerateDiff = false

    private let store: ItemStore
    private let embeddingIndex = LocalEmbeddingIndex()
    private let audioService = RealtimeAudioService()
    private var provider: RealtimeSessionProvider?
    private var asrClient: DoubaoRealtimeASRClient?
    private var eventTask: Task<Void, Never>?
    private var sessionStart: Date?
    private var latestAssistantText: String?
    private var pendingProposal: PendingProposal?
    private var suppressAudioPlayback = false
    private var debugLogger: VoiceSessionDebugLogger?
    private var lastConfirmTime: Date?
    private var lastAutoCapturedText: String?
    private var lastAutoCaptureTime: Date?
    private var proposalCaptureActive = false
    private var proposalCaptureBuffer = ""
    private var proposalCaptureStartedAt: Date?
    private var proposalMuteTask: Task<Void, Never>?
    private var proposalMuteRetryTask: Task<Void, Never>?
    private var proposalIgnoreUntil: Date?
    private var lastLevelUpdate = Date.distantPast
    private var lastOutputLevelUpdate = Date.distantPast
    private var latestUserTranscript: String?
    private var hasReceivedUserTranscript = false
    private var suppressAssistantUntilUser = false
    private var pendingGreeting = false
    private var pendingInitialContext: String?
    private var greetingAudioGraceUntil: Date?
    private let greetingExpectedNormalized = "hi what can i do for you"
    private var greetingBufferNormalized = ""
    private let useDiffBasedSession = true
    private var lastSessionTimestamp: Date?
    private var lastDuplicatePromptItemId: UUID?
    private var lastDuplicatePromptAt: Date?
    private var duplicatePromptTask: Task<Void, Never>?
    private let duplicatePromptDebounceSeconds: TimeInterval = 0.8
    private var lastDiffTranscript: String?
    private var lastDiffFullTranscript: String?
    private var lastDiffItemsSnapshot: [Item] = []
    private var lastDiffUsedReducedContext = false
    private let diffItemLimit = 80
    private let diffItemLimitReduced = 30
    private let diffTranscriptLineLimit = 100
    private let diffTranscriptLineLimitReduced = 50
    private let diffTranscriptCharLimit = 4000
    private let diffTranscriptCharLimitReduced = 2400
    private var pendingEmbeddingMetrics: PendingEmbeddingMetrics?
    private var asrSource: String {
        UserDefaults.standard.string(forKey: "voiceSessionASRSource") ?? "doubao"
    }

    private var embeddingDuplicatePromptsEnabled: Bool {
        if UserDefaults.standard.object(forKey: "voiceSessionEmbeddingDuplicatesEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "voiceSessionEmbeddingDuplicatesEnabled")
    }

    private var embeddingDuplicateMinScore: Double {
        let value = UserDefaults.standard.double(forKey: "voiceSessionEmbeddingMinScore")
        if value == 0 {
            return 0.25
        }
        return min(max(value, 0.05), 0.9)
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
                                self?.handleRemoteTranscript(text, isFinal: false)
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
                    self.hasReceivedUserTranscript = false
                    self.suppressAssistantUntilUser = true
                    self.pendingGreeting = true
                    self.greetingAudioGraceUntil = nil
                    self.greetingBufferNormalized = ""
                    try self.audioService.startCapture(onAudio: { [weak self] data in
                        self?.handleAudioLevel(from: data)
                        Task { try? await self?.provider?.sendAudio(data) }
                        Task { try? await self?.asrClient?.sendAudio(data) }
                    }, onTranscription: useLocalTranscription ? { [weak self] text in
                        Task { @MainActor in
                            self?.handleLocalTranscript(text, isFinal: false)
                        }
                    } : nil)
                    self.audioService.startPlayback()
                }
                let startDate = Date()
                await MainActor.run {
                    self.sessionStart = startDate
                    if UserDefaults.standard.bool(forKey: "voiceSessionDebugLoggingEnabled") {
                        VoiceSessionDebugLogger.clearAllLogs()
                        self.debugLogger = VoiceSessionDebugLogger(sessionStart: startDate)
                    }
                    self.isActive = true
                    self.statusText = "Streaming"
                    self.startEventLoop(provider: provider)
                }

                let context = await MainActor.run { self.sessionItemsContext() }
                await MainActor.run {
                    self.pendingInitialContext = context.isEmpty ? nil : "Context only. Do not respond yet.\n\(context)"
                }
                try await provider.sendText("Please greet the user by saying: \"Hi, what can I do for you?\" Then wait for their reply before responding to any context.")
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
                self.suppressAudioPlayback = false
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
                let logTimestamp = self.sessionStart
                self.lastSessionTimestamp = logTimestamp
                self.debugLogger?.logTranscript(self.transcript)
                let artifacts = self.writeDebugArtifactsIfNeeded(sessionTimestamp: logTimestamp)
                self.persistSummaryIfNeeded()
                if UserDefaults.standard.bool(forKey: "voiceSessionDebugLoggingEnabled") {
                    let debugInfoURL = VoiceSessionDebugLogger.writeDebugInfoFile()
                    let embeddingLogs = self.embeddingMetricsLogURLs(since: logTimestamp)
                    let runLogs = self.collectRunLogs(
                        artifacts: artifacts,
                        debugInfoURL: debugInfoURL,
                        additionalLogs: embeddingLogs
                    )
                    self.latestRunLogFiles = runLogs
                    VoiceSessionDebugLogger.storeLatestRunLogFiles(runLogs)
                }
                self.flushPendingEmbeddingMetrics(reason: "no_response")
                self.suppressAssistantUntilUser = false
                self.hasReceivedUserTranscript = false
                self.pendingGreeting = false
                self.pendingInitialContext = nil
                self.greetingAudioGraceUntil = nil
                self.greetingBufferNormalized = ""
                self.audioService.stopAll()
            }
            await self.generateDiffProposalIfNeeded()
            await MainActor.run {
                self.debugLogger = nil
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
                let canPlayPreUser = self.pendingGreeting || (self.greetingAudioGraceUntil.map { Date() < $0 } ?? false)
                if !self.suppressAudioPlayback, (!self.suppressAssistantUntilUser || canPlayPreUser) {
                    self.audioService.playAudioChunk(data)
                }
                self.handleOutputLevel(from: data)
            }
        case .text(let text):
            Task { @MainActor in
                self.handleAssistantText(text)
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
            markUserTranscriptReceived(text)
            transcript = setLine(transcript, prefix: "You", text: text)
            handleUserVoiceCommand(text, isFinal: false)
            return
        }
        if let header = payload["header"] as? [String: Any],
           let name = header["name"] as? String {
            if name == "user_speech_recognition" {
                if let text = transcriptValue(from: payload, key: "transcript") {
                    print("[VoiceSession][User] \(text)")
                    transcript = setLine(transcript, prefix: "You", text: text)
                    handleUserVoiceCommand(text, isFinal: false)
                }
                return
            }
            if name == "user_speech_end" {
                if let text = transcriptValue(from: payload, key: "final_transcript") {
                    print("[VoiceSession][User] \(text)")
                    transcript = setLine(transcript, prefix: "You", text: text)
                    handleUserVoiceCommand(text, isFinal: true)
                }
                return
            }
        }
        if let text = payload["asr_text"] as? String {
            print("[VoiceSession][User] \(text)")
            transcript = setLine(transcript, prefix: "You", text: text)
            handleUserVoiceCommand(text, isFinal: false)
            return
        }

        if let text = payload["text"] as? String, payload["content"] == nil {
            print("[VoiceSession][User] \(text)")
            transcript = setLine(transcript, prefix: "You", text: text)
            handleUserVoiceCommand(text, isFinal: false)
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

    private func handleLocalTranscript(_ text: String, isFinal: Bool) {
        guard text != latestUserTranscript else { return }
        latestUserTranscript = text
        markUserTranscriptReceived(text)
        transcript = setLine(transcript, prefix: "You", text: text)
        handleUserVoiceCommand(text, isFinal: isFinal)
    }

    private func handleRemoteTranscript(_ text: String, isFinal: Bool) {
        guard text != latestUserTranscript else { return }
        latestUserTranscript = text
        markUserTranscriptReceived(text)
        transcript = setLine(transcript, prefix: "You", text: text)
        handleUserVoiceCommand(text, isFinal: isFinal)
    }

    private func markUserTranscriptReceived(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        hasReceivedUserTranscript = true
        suppressAssistantUntilUser = false
        pendingGreeting = false
        greetingAudioGraceUntil = nil
    }

    private func handleUserVoiceCommand(_ text: String, isFinal: Bool) {
        let command = text.lowercased()

        if let expansion = parseHistoryExpansion(from: command) {
            Task { try? await sendHistoryExpansion(months: expansion) }
            return
        }

        if let decision = parseDuplicateDecision(from: command) {
            recordEmbeddingDecision(decision)
        }

        scheduleDuplicatePrompt(for: text, isFinal: isFinal)

        let normalized = normalizeCommand(command)
        if pendingProposal != nil, isConfirmCommand(normalized) {
            lastConfirmTime = Date()
            applyPendingProposal(silent: false)
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

    private func parseDuplicateDecision(from command: String) -> String? {
        let normalized = normalizeCommand(command)
        if normalized.contains("merge") || command.contains("合并") {
            return "merge"
        }
        if normalized.contains("new") || normalized.contains("create new") || command.contains("新的") || command.contains("新建") {
            return "new"
        }
        if normalized.contains("skip") || normalized.contains("no") || command.contains("跳过") || command.contains("不要") {
            return "skip"
        }
        return nil
    }

    private func scheduleDuplicatePrompt(for text: String, isFinal: Bool) {
        duplicatePromptTask?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isFinal {
            maybePromptDuplicate(for: text)
            return
        }
        let capturedText = text
        duplicatePromptTask = Task { [weak self] in
            let delay = UInt64((self?.duplicatePromptDebounceSeconds ?? 0.8) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.latestUserTranscript == capturedText else { return }
                self.maybePromptDuplicate(for: capturedText)
            }
        }
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
        if suppressAssistantUntilUser {
            if pendingGreeting {
                if shouldAllowGreetingChunk(text) {
                    if greetingBufferNormalized.count >= greetingExpectedNormalized.count {
                        pendingGreeting = false
                        greetingAudioGraceUntil = Date().addingTimeInterval(1.0)
                        if let context = pendingInitialContext {
                            pendingInitialContext = nil
                            Task { try? await provider?.sendText(context) }
                        }
                    }
                } else {
                    debugLogger?.log("Suppressed pre-user assistant text: \(text)")
                    return
                }
            } else {
                debugLogger?.log("Suppressed pre-user assistant text: \(text)")
                return
            }
        }
        if let ignoreUntil = proposalIgnoreUntil, Date() < ignoreUntil {
            return
        }
        if proposalCaptureActive || isProposalMarker(text) || isProposalMarkerFragment(text) {
            handleProposalCapture(text)
            return
        }

        debugLogger?.log("Assistant text: \(text)")
        if useDiffBasedSession {
            print("[VoiceSession][Assistant] \(text)")
            transcript = appendLine(transcript, prefix: "Assistant", text: text)
            if let assistantLine = latestAssistantLine(from: transcript), !assistantLine.isEmpty {
                latestAssistantText = assistantLine
            }
            return
        }

        let (cleaned, proposal) = extractProposal(from: text)
        if let proposal {
            pendingProposal = proposal
            if case .create(let draft) = proposal.action, handleDuplicateProposal(draft) {
                return
            }
        }
        print("[VoiceSession][Assistant] \(cleaned)")
        let updatedTranscript = appendLine(transcript, prefix: "Assistant", text: cleaned)
        transcript = updatedTranscript
        if let assistantLine = latestAssistantLine(from: updatedTranscript), !assistantLine.isEmpty {
            latestAssistantText = assistantLine
        }
        let assistantLine = latestAssistantText ?? cleaned
        if proposal != nil {
            if shouldAutoApplyProposal(for: assistantLine) {
                lastConfirmTime = Date()
                applyPendingProposal(silent: true)
            }
        } else if shouldAutoApplyProposal(for: assistantLine) {
            autoCaptureFromTranscriptIfNeeded()
        }
    }

    private func shouldAllowGreetingChunk(_ text: String) -> Bool {
        let normalizedChunk = normalizeGreetingText(text)
        guard !normalizedChunk.isEmpty else { return true }
        let candidate = greetingBufferNormalized + (greetingBufferNormalized.isEmpty ? "" : " ") + normalizedChunk
        let trimmedCandidate = candidate.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if greetingExpectedNormalized.hasPrefix(trimmedCandidate) {
            greetingBufferNormalized = trimmedCandidate
            return true
        }
        return false
    }

    private func normalizeGreetingText(_ text: String) -> String {
        let lowered = text.lowercased()
        let filtered = lowered.filter { $0.isLetter || $0 == " " }
        return filtered.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldAutoApplyProposal(for assistantText: String) -> Bool {
        let normalized = assistantText.lowercased()
        let normalizedCompact = normalized.filter { !$0.isWhitespace && !$0.isNewline }
        if normalized.contains("confirm") || normalized.contains("reject") {
            return false
        }
        let questionPhrases = ["want me", "should i", "do you want", "is that ok", "okay to", "can i"]
        if questionPhrases.contains(where: { normalized.contains($0) }) {
            return false
        }
        let actionPhrases = [
            "i'll add",
            "i will add",
            "adding",
            "i've added",
            "i have added",
            "added it",
            "added to",
            "i'll create",
            "i will create",
            "adding that",
            "got it",
            "noted it down",
            "i've noted",
            "i have noted",
            "noted",
            "recorded",
            "scheduled",
            "i've scheduled",
            "i have scheduled",
            "i'll mark",
            "i will mark",
            "saved",
            "已为你添加",
            "已经帮你添加",
            "已经帮你安排",
            "已经帮你记录",
            "已记录",
            "已记录下",
            "已添加",
            "已安排",
            "已记下",
            "已帮你",
            "我已经帮你",
            "我已为你",
            "我已记录",
            "我已记录下",
            "我已添加"
        ]
        return actionPhrases.contains { phrase in
            if normalized.contains(phrase) {
                return true
            }
            let compactPhrase = phrase.filter { !$0.isWhitespace && !$0.isNewline }
            return normalizedCompact.contains(compactPhrase)
        }
    }

    private func autoCaptureFromTranscriptIfNeeded() {
        let trimmed = (latestUserTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        if let lastText = lastAutoCapturedText,
           lastText == trimmed,
           let lastTime = lastAutoCaptureTime,
           now.timeIntervalSince(lastTime) < 5 {
            return
        }
        let title = trimmed.count > 80 ? String(trimmed.prefix(80)) : trimmed
        store.addItem(
            type: .task,
            title: title,
            details: "",
            rawText: trimmed,
            priority: .normal,
            dueDate: nil,
            tags: [],
            project: nil
        )
        lastAutoCapturedText = trimmed
        lastAutoCaptureTime = now
    }

    private func latestAssistantLine(from transcript: String) -> String? {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            if line.hasPrefix("Assistant:") {
                return line.replacingOccurrences(of: "Assistant:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func handleDuplicateProposal(_ draft: DraftItem) -> Bool {
        guard let similar = findSimilarItem(for: draft) else { return false }
        let summary = "Similar item found: \(similar.title). Ask the user whether to merge or create a new item. If they say merge, send PROPOSAL_JSON with action=update and targetTitle=\(similar.title). If they say new, send a create PROPOSAL_JSON for \(draft.title)."
        if let provider {
            Task { try? await provider.sendText(summary) }
        }
        transcript = appendLine(transcript, prefix: "System", text: "Similar item found. Asking for merge or new.")
        return true
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

    private func maybePromptDuplicate(for text: String) {
        guard useDiffBasedSession, embeddingDuplicatePromptsEnabled, let provider else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return }
        var usedFallback = false
        var matches = embeddingIndex.search(query: trimmed, items: store.items, limit: 5, minScore: embeddingDuplicateMinScore)
        if matches.isEmpty {
            matches = fallbackSimilarityMatches(for: trimmed, items: store.items)
            usedFallback = !matches.isEmpty
        }
        guard let topMatch = matches.first else { return }
        let now = Date()
        if let lastId = lastDuplicatePromptItemId,
           lastId == topMatch.item.id,
           let lastAt = lastDuplicatePromptAt,
           now.timeIntervalSince(lastAt) < 30 {
            return
        }
        lastDuplicatePromptItemId = topMatch.item.id
        lastDuplicatePromptAt = now
        recordPendingEmbeddingMetrics(utterance: trimmed, matches: matches)
        let message = duplicateCandidatePrompt(utterance: trimmed, matches: matches)
        Task { try? await provider.sendText(message) }
        let source = usedFallback ? "fallback" : "embedding"
        transcript = appendLine(transcript, prefix: "System", text: "Duplicate candidate detected (\(source)) for \(topMatch.item.title).")
    }

    private func fallbackSimilarityMatches(for text: String, items: [Item]) -> [EmbeddingMatch] {
        let normalizedQuery = normalizeSimilarityText(text)
        guard !normalizedQuery.isEmpty else { return [] }
        let queryTokens = Set(normalizedQuery.split(separator: " "))
        guard !queryTokens.isEmpty else { return [] }
        var matches: [EmbeddingMatch] = []
        for item in items where item.type == .task || item.type == .idea {
            let combined = normalizeSimilarityText("\(item.title) \(item.details)")
            guard !combined.isEmpty else { continue }
            let itemTokens = Set(combined.split(separator: " "))
            guard !itemTokens.isEmpty else { continue }
            let intersection = queryTokens.intersection(itemTokens)
            let overlap = Double(intersection.count) / Double(max(queryTokens.count, itemTokens.count))
            if intersection.count >= 2 || overlap >= 0.5 {
                matches.append(EmbeddingMatch(item: item, score: max(overlap, 0.6)))
            }
        }
        let sorted = matches.sorted { $0.score > $1.score }
        return Array(sorted.prefix(5))
    }

    private func duplicateCandidatePrompt(utterance: String, matches: [EmbeddingMatch]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none
        let lines = matches.enumerated().map { index, match in
            let item = match.item
            let dueDate = item.dueDate.map { dateFormatter.string(from: $0) } ?? "none"
            let project = item.project?.isEmpty == false ? item.project! : "none"
            let tags = item.tags.isEmpty ? "none" : item.tags.joined(separator: ", ")
            let score = String(format: "%.2f", match.score)
            return "\(index + 1)) [\(item.type.rawValue)] \(item.title) (id: \(item.id.uuidString), project: \(project), tags: \(tags), due: \(dueDate), score: \(score))"
        }
        let list = lines.joined(separator: "\n")
        return """
        INTERNAL_RULE: If any candidate looks similar, you MUST call it out and ask whether to merge or keep it as a new item. Do not ignore this.
        The user just mentioned: "\(utterance)".
        Possible similar items:
        \(list)
        If any item is a duplicate, point it out and ask whether to merge or keep it as a new item. If none are duplicates, respond normally without mentioning duplicates.
        """
    }

    private func recordPendingEmbeddingMetrics(utterance: String, matches: [EmbeddingMatch]) {
        flushPendingEmbeddingMetrics(reason: "no_response")
        let candidates = matches.map { match in
            EmbeddingMetricsCandidate(
                id: match.item.id.uuidString,
                type: match.item.type.rawValue,
                title: match.item.title,
                details: match.item.details,
                project: match.item.project,
                tags: match.item.tags,
                createdAt: isoTimestamp(match.item.createdAt),
                score: match.score
            )
        }
        pendingEmbeddingMetrics = PendingEmbeddingMetrics(
            timestamp: Date(),
            modelVersion: embeddingIndex.currentModelVersion(),
            utterance: utterance,
            candidates: candidates
        )
    }

    private func recordEmbeddingDecision(_ decision: String) {
        guard let pending = pendingEmbeddingMetrics else { return }
        let entry = EmbeddingMetricsEntry(
            timestamp: isoTimestamp(pending.timestamp),
            modelVersion: pending.modelVersion,
            utterance: pending.utterance,
            decision: decision,
            candidates: pending.candidates
        )
        appendEmbeddingMetricsEntry(entry)
        pendingEmbeddingMetrics = nil
    }

    private func flushPendingEmbeddingMetrics(reason: String) {
        guard let pending = pendingEmbeddingMetrics else { return }
        let entry = EmbeddingMetricsEntry(
            timestamp: isoTimestamp(pending.timestamp),
            modelVersion: pending.modelVersion,
            utterance: pending.utterance,
            decision: reason,
            candidates: pending.candidates
        )
        appendEmbeddingMetricsEntry(entry)
        pendingEmbeddingMetrics = nil
    }

    private func appendEmbeddingMetricsEntry(_ entry: EmbeddingMetricsEntry) {
        guard let fileURL = embeddingMetricsLogURL(modelVersion: entry.modelVersion) else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(entry) else { return }
        let lineData = data + Data("\n".utf8)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let fileHandle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? fileHandle.close() }
        _ = try? fileHandle.seekToEnd()
        fileHandle.write(lineData)

        appendEmbeddingMetricsReadableEntry(entry)
    }

    private func embeddingMetricsLogURL(modelVersion: String) -> URL? {
        guard let directory = VoiceSessionDebugLogger.logsDirectoryURL() else { return nil }
        let sanitized = modelVersion.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("voice-embedding-metrics-\(sanitized).jsonl")
    }

    private func appendEmbeddingMetricsReadableEntry(_ entry: EmbeddingMetricsEntry) {
        guard let fileURL = embeddingMetricsReadableLogURL(modelVersion: entry.modelVersion) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let fileHandle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? fileHandle.close() }
        _ = try? fileHandle.seekToEnd()
        let payload = formatEmbeddingMetricsReadableEntry(entry)
        guard let data = payload.data(using: .utf8) else { return }
        fileHandle.write(data)
    }

    private func embeddingMetricsReadableLogURL(modelVersion: String) -> URL? {
        guard let directory = VoiceSessionDebugLogger.logsDirectoryURL() else { return nil }
        let sanitized = modelVersion.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("voice-embedding-metrics-readable-\(sanitized).txt")
    }

    private func formatEmbeddingMetricsReadableEntry(_ entry: EmbeddingMetricsEntry) -> String {
        var lines: [String] = []
        lines.append("Timestamp: \(entry.timestamp)")
        lines.append("Decision: \(entry.decision)")
        lines.append("Utterance: \(entry.utterance)")
        if entry.candidates.isEmpty {
            lines.append("Candidates: none")
        } else {
            lines.append("Candidates:")
            for candidate in entry.candidates {
                let score = String(format: "%.2f", candidate.score)
                let tags = candidate.tags.isEmpty ? "none" : candidate.tags.joined(separator: ", ")
                let project = candidate.project?.isEmpty == false ? candidate.project! : "none"
                lines.append("- [\(candidate.type)] \(candidate.title) (score: \(score), project: \(project), tags: \(tags), created: \(candidate.createdAt), id: \(candidate.id))")
                if !candidate.details.isEmpty {
                    lines.append("  Details: \(candidate.details)")
                }
            }
        }
        lines.append("----")
        return lines.joined(separator: "\n") + "\n"
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

    private func sessionItemsContext() -> String {
        let items = store.items
        guard !items.isEmpty else { return "" }
        return formatContext(items: items, title: "Inbox items:")
    }

    private func historyContext(months: Int) -> String {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        let items = store.items.filter { $0.createdAt >= cutoff }
        guard !items.isEmpty else { return "" }
        return formatContext(items: items, title: "Context items (last \(months) months):")
    }

    private func formatContext(items: [Item], title: String) -> String {
        let lines = items.map { item in
            let dueDate = item.dueDate.map { Item.dueDateDisplay($0) } ?? "none"
            let project = item.project?.isEmpty == false ? item.project! : "none"
            let tags = item.tags.isEmpty ? "none" : item.tags.joined(separator: ", ")
            return "- [\(item.type.rawValue)] \(item.title) (id: \(item.id.uuidString), project: \(project), tags: \(tags), due: \(dueDate))"
        }
        return title + "\n" + lines.joined(separator: "\n")
    }

    private func persistSummaryIfNeeded() {
        let fallbackTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackTranscript.isEmpty else { return }
        let end = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let startText = sessionStart.map { formatter.string(from: $0) } ?? formatter.string(from: end)
        let endText = formatter.string(from: end)
        let title = "Discussion with Doubao \(startText)–\(endText)"
        store.addItem(type: .note, title: title, details: fallbackTranscript, rawText: fallbackTranscript)
        debugLogger?.log("Saved summary note: \(title)")
        latestAssistantText = nil
        sessionStart = nil
    }

    @MainActor
    private func generateDiffProposalIfNeeded() async {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        let baseItems = store.items
        writeVoiceItemsSnapshotLog(label: "before-diff")
        canGenerateDiff = true
        statusText = "Preparing Review"
        let contexts = makeDiffContexts(transcript: trimmedTranscript, items: baseItems)
        var lastContext = contexts[0]
        lastDiffTranscript = lastContext.transcript
        lastDiffFullTranscript = trimmedTranscript
        lastDiffItemsSnapshot = lastContext.items
        lastDiffUsedReducedContext = lastContext.isReduced
        debugLogger?.log("Diff generation started (items=\(lastContext.items.count), transcriptChars=\(lastContext.transcript.count))")
        let service = VoiceSessionDiffService(logger: { [weak self] message in
            self?.debugLogger?.log(message)
        })
        do {
            let start = Date()
            let diff = try await generateDiffWithFallback(using: service, contexts: contexts, lastContext: &lastContext, fullTranscript: trimmedTranscript)
            let duration = Date().timeIntervalSince(start)
            lastDiffTranscript = lastContext.transcript
            lastDiffFullTranscript = trimmedTranscript
            lastDiffItemsSnapshot = lastContext.items
            lastDiffUsedReducedContext = lastContext.isReduced
            debugLogger?.log(String(format: "Diff generation completed in %.2fs (%@)", duration, lastContext.label))
            let normalized = normalizeDiff(diff, items: store.items)
            if normalized.isEmpty {
                debugLogger?.log("Diff generation returned empty diff")
                statusText = "Idle"
                return
            }
            if let diffLogURL = writeDiffLog(normalized) {
                appendRunLog(diffLogURL)
            }
            pendingDiff = normalized
            isShowingDiffReview = true
            statusText = "Review Ready"
            transcript = ""
            latestUserTranscript = nil
        } catch {
            lastDiffTranscript = lastContext.transcript
            lastDiffFullTranscript = trimmedTranscript
            lastDiffItemsSnapshot = lastContext.items
            lastDiffUsedReducedContext = lastContext.isReduced
            debugLogger?.log("Diff generation failed (\(lastContext.label)): \(error.localizedDescription)")
            if let errorLogURL = writeDiffErrorLog(
                error.localizedDescription,
                attempt: lastContext.label,
                transcriptChars: lastContext.transcript.count,
                itemsCount: lastContext.items.count
            ) {
                appendRunLog(errorLogURL)
            }
            let suffix = lastContext.isReduced ? " (reduced payload)" : ""
            diffErrorMessage = "Diff generation failed\(suffix): \(error.localizedDescription)"
            isShowingDiffError = true
            transcript = appendLine(transcript, prefix: "System", text: "Diff generation failed. You can retry from Voice settings.")
            statusText = "Idle"
        }
    }

    @MainActor
    func retryDiffProposal() {
        guard let transcript = lastDiffTranscript, !transcript.isEmpty else { return }
        let fullTranscript = lastDiffFullTranscript ?? transcript
        statusText = "Preparing Review"
        isShowingDiffError = false
        diffErrorMessage = ""
        canGenerateDiff = true
        let contexts = makeDiffContexts(transcript: transcript, items: lastDiffItemsSnapshot)
        var lastContext = contexts[0]
        debugLogger?.log("Diff generation retry started (items=\(lastContext.items.count), transcriptChars=\(lastContext.transcript.count))")
        let service = VoiceSessionDiffService(logger: { [weak self] message in
            self?.debugLogger?.log(message)
        })
        Task { [weak self] in
            guard let self else { return }
            do {
                let start = Date()
                let diff = try await self.generateDiffWithFallback(using: service, contexts: contexts, lastContext: &lastContext, fullTranscript: fullTranscript)
                let duration = Date().timeIntervalSince(start)
                let normalized = self.normalizeDiff(diff, items: self.store.items)
                await MainActor.run {
                    self.lastDiffTranscript = lastContext.transcript
                    self.lastDiffFullTranscript = fullTranscript
                    self.lastDiffItemsSnapshot = lastContext.items
                    self.lastDiffUsedReducedContext = lastContext.isReduced
                    self.debugLogger?.log(String(format: "Diff retry completed in %.2fs (%@)", duration, lastContext.label))
                    if normalized.isEmpty {
                        self.debugLogger?.log("Diff retry returned empty diff")
                        self.statusText = "Idle"
                        return
                    }
                    if let diffLogURL = self.writeDiffLog(normalized) {
                        self.appendRunLog(diffLogURL)
                    }
                    self.pendingDiff = normalized
                    self.isShowingDiffReview = true
                    self.statusText = "Review Ready"
                }
            } catch {
                await MainActor.run {
                    self.lastDiffTranscript = lastContext.transcript
                    self.lastDiffFullTranscript = fullTranscript
                    self.lastDiffItemsSnapshot = lastContext.items
                    self.lastDiffUsedReducedContext = lastContext.isReduced
                    self.debugLogger?.log("Diff retry failed (\(lastContext.label)): \(error.localizedDescription)")
                    if let errorLogURL = self.writeDiffErrorLog(
                        error.localizedDescription,
                        attempt: lastContext.label,
                        transcriptChars: lastContext.transcript.count,
                        itemsCount: lastContext.items.count
                    ) {
                        self.appendRunLog(errorLogURL)
                    }
                    let suffix = lastContext.isReduced ? " (reduced payload)" : ""
                    self.diffErrorMessage = "Diff generation failed\(suffix): \(error.localizedDescription)"
                    self.isShowingDiffError = true
                    self.statusText = "Idle"
                }
            }
        }
    }

    private struct DiffContext {
        let transcript: String
        let items: [Item]
        let label: String
        let isReduced: Bool
    }

    private func makeDiffContexts(transcript: String, items: [Item]) -> [DiffContext] {
        let primaryTranscript = trimTranscriptForDiff(
            transcript,
            lineLimit: diffTranscriptLineLimit,
            charLimit: diffTranscriptCharLimit
        )
        let reducedTranscript = trimTranscriptForDiff(
            transcript,
            lineLimit: diffTranscriptLineLimitReduced,
            charLimit: diffTranscriptCharLimitReduced
        )
        let primary = DiffContext(
            transcript: primaryTranscript,
            items: trimItemsForDiff(items, limit: diffItemLimit),
            label: "full",
            isReduced: false
        )
        let reduced = DiffContext(
            transcript: reducedTranscript,
            items: trimItemsForDiff(items, limit: diffItemLimitReduced),
            label: "reduced",
            isReduced: true
        )
        return [primary, reduced]
    }

    private func generateDiffWithFallback(
        using service: VoiceSessionDiffService,
        contexts: [DiffContext],
        lastContext: inout DiffContext,
        fullTranscript: String
    ) async throws -> VoiceSessionDiff {
        var lastError: Error?
        for (index, context) in contexts.enumerated() {
            lastContext = context
            debugLogger?.log("Diff generation attempt (\(context.label)) (items=\(context.items.count), transcriptChars=\(context.transcript.count))")
            do {
                return try await service.proposeDiff(
                    transcript: context.transcript,
                    deletionTranscript: fullTranscript,
                    items: context.items
                )
            } catch {
                lastError = error
                if isTimeoutError(error), index < contexts.count - 1 {
                    debugLogger?.log("Diff generation timed out; retrying with reduced payload")
                    continue
                }
                throw error
            }
        }
        throw lastError ?? VoiceSessionDiffError.invalidResponse("Diff generation failed")
    }

    private func trimTranscriptForDiff(_ transcript: String, lineLimit: Int, charLimit: Int) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let recentLines = lines.suffix(lineLimit).joined(separator: "\n")
        if recentLines.count <= charLimit {
            return recentLines
        }
        return String(recentLines.suffix(charLimit))
    }

    private func trimItemsForDiff(_ items: [Item], limit: Int) -> [Item] {
        let filtered = items.filter { $0.type == .task || $0.type == .idea }
        let sorted = filtered.sorted { $0.createdAt > $1.createdAt }
        guard sorted.count > limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    @MainActor
    func applyDiff(_ diff: VoiceSessionDiff, selection: VoiceSessionDiffSelection) {
        let mergeSourceIds = selection.mergeSourceIds
        let createItems = diff.creates.filter { selection.createTempIds.contains($0.tempId) && !mergeSourceIds.contains($0.tempId) }
        for create in createItems {
            store.addItem(
                type: create.type,
                title: create.title,
                details: create.details,
                rawText: create.details,
                priority: create.priority,
                dueDate: create.dueDate,
                tags: create.tags,
                project: create.project
            )
        }

        let createLookup = Dictionary(uniqueKeysWithValues: diff.creates.map { ($0.tempId, $0) })
        for merge in diff.merges where selection.mergeSourceIds.contains(merge.sourceTempId) {
            guard let target = store.items.first(where: { $0.id.uuidString == merge.targetId }) else { continue }
            guard let source = createLookup[merge.sourceTempId] else { continue }
            store.updateItem(id: target.id) { item in
                if item.details != source.details, !source.details.isEmpty {
                    if item.details.isEmpty {
                        item.details = source.details
                    } else {
                        item.details += "\n" + source.details
                    }
                }
                if let sourceDueDate = source.dueDate {
                    if item.dueDate != sourceDueDate {
                        item.dueDate = sourceDueDate
                    }
                }
                if item.priority.rawValue < source.priority.rawValue {
                    item.priority = source.priority
                }
                let combinedTags = Set(item.tags).union(source.tags)
                item.tags = Array(combinedTags)
                if item.project == nil || item.project?.isEmpty == true {
                    item.project = source.project
                }
            }
        }

        for update in diff.updates where selection.updateIds.contains(update.id) {
            guard let target = store.items.first(where: { $0.id.uuidString == update.id }) else { continue }
            store.updateItem(id: target.id) { item in
                if let title = update.changes.title { item.title = title }
                if let details = update.changes.details { item.details = details }
                if let dueDate = update.changes.dueDate { item.dueDate = dueDate }
                if let priority = update.changes.priority { item.priority = priority }
                if let project = update.changes.project { item.project = project }
                if let tags = update.changes.tags { item.tags = tags }
            }
        }

        for delete in diff.deletes where selection.deleteIds.contains(delete.id) {
            if let target = store.items.first(where: { $0.id.uuidString == delete.id }) {
                store.deleteItem(id: target.id)
            }
        }

        writeVoiceItemsSnapshotLog(label: "after-diff")
        pendingDiff = nil
        isShowingDiffReview = false
        statusText = "Idle"
    }

    @MainActor
    func dismissDiffReview() {
        pendingDiff = nil
        isShowingDiffReview = false
        statusText = "Idle"
    }

    private func normalizeDiff(_ diff: VoiceSessionDiff, items: [Item]) -> VoiceSessionDiff {
        let existingById = Dictionary(uniqueKeysWithValues: items.map { ($0.id.uuidString, $0) })
        var deleteLookup = Dictionary(uniqueKeysWithValues: diff.deletes.map { ($0.id, $0) })
        let updateIds = Set(diff.updates.map { $0.id })

        for merge in diff.merges {
            guard let target = existingById[merge.targetId] else { continue }
            let normalizedTitle = normalizeTitle(target.title)
            let targetTags = Set(target.tags.map { $0.lowercased() })
            let targetProject = target.project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let targetDueDate = target.dueDate
            for item in items where item.id != target.id {
                guard item.type == target.type else { continue }
                guard normalizeTitle(item.title) == normalizedTitle else { continue }
                let itemProject = item.project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !targetProject.isEmpty || !itemProject.isEmpty {
                    guard targetProject.caseInsensitiveCompare(itemProject) == .orderedSame else { continue }
                }
                let itemTags = Set(item.tags.map { $0.lowercased() })
                if !targetTags.isEmpty || !itemTags.isEmpty {
                    guard !targetTags.intersection(itemTags).isEmpty else { continue }
                }
                if let targetDate = targetDueDate, let itemDate = item.dueDate {
                    let daysApart = Calendar.current.dateComponents([.day], from: targetDate, to: itemDate).day ?? 0
                    if abs(daysApart) > 3 { continue }
                }
                let itemId = item.id.uuidString
                guard itemId != merge.targetId else { continue }
                guard !updateIds.contains(itemId) else { continue }
                if deleteLookup[itemId] == nil {
                    deleteLookup[itemId] = VoiceSessionDiffDelete(
                        id: itemId,
                        reason: "Merged duplicate into \(target.title)"
                    )
                }
            }
        }

        return VoiceSessionDiff(
            creates: diff.creates,
            updates: diff.updates,
            merges: diff.merges,
            deletes: Array(deleteLookup.values)
        )
    }

    private func normalizeTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func writeDiffLog(_ diff: VoiceSessionDiff) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(diff),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        let timestamp = lastSessionTimestamp ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatter.string(from: timestamp)
        return VoiceSessionDebugLogger.writeLogFile(named: "voice-diff-\(suffix).json", contents: content)
    }

    private func writeDiffErrorLog(
        _ message: String,
        attempt: String,
        transcriptChars: Int,
        itemsCount: Int
    ) -> URL? {
        let payload: [String: Any] = [
            "timestamp": isoTimestamp(Date()),
            "error": message,
            "attempt": attempt,
            "transcriptChars": transcriptChars,
            "itemsCount": itemsCount
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let timestamp = lastSessionTimestamp ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatter.string(from: timestamp)
        return VoiceSessionDebugLogger.writeLogFile(named: "voice-diff-error-\(suffix).json", contents: content)
    }

    private func writeVoiceItemsSnapshotLog(label: String) {
        let items = store.items.filter { $0.type == .task || $0.type == .idea }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let payload = items.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "type": item.type.rawValue,
                "title": item.title,
                "details": item.details,
                "dueDate": item.dueDate.map { formatter.string(from: $0) } as Any,
                "tags": item.tags,
                "project": item.project as Any,
                "createdAt": isoTimestamp(item.createdAt)
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let content = String(data: data, encoding: .utf8) else { return }
        let timestamp = lastSessionTimestamp ?? Date()
        let formatterName = DateFormatter()
        formatterName.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatterName.string(from: timestamp)
        if let url = VoiceSessionDebugLogger.writeLogFile(named: "voice-items-\(label)-\(suffix).json", contents: content) {
            appendRunLog(url)
        }
    }

    @MainActor
    private func appendRunLog(_ url: URL) {
        guard !latestRunLogFiles.contains(url) else { return }
        latestRunLogFiles.append(url)
        if UserDefaults.standard.bool(forKey: "voiceSessionDebugLoggingEnabled") {
            VoiceSessionDebugLogger.storeLatestRunLogFiles(latestRunLogFiles)
        }
    }

    private func writeDebugArtifactsIfNeeded(sessionTimestamp: Date?) -> [URL] {
        let timestamp = sessionTimestamp ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatter.string(from: timestamp)
        var created: [URL] = []
        if let monitorLog = makeVoiceMonitorLog() {
            if let url = VoiceSessionDebugLogger.writeLogFile(named: "voice-monitor-\(suffix).json", contents: monitorLog) {
                created.append(url)
            }
        }
        if let itemsLog = makeItemsSnapshotLog() {
            if let url = VoiceSessionDebugLogger.writeLogFile(named: "voice-items-\(suffix).json", contents: itemsLog) {
                created.append(url)
            }
        }
        return created
    }

    private func collectRunLogs(artifacts: [URL], debugInfoURL: URL?, additionalLogs: [URL] = []) -> [URL] {
        var logs: [URL] = []
        if let debugLogger {
            logs.append(debugLogger.logURL)
        }
        logs.append(contentsOf: artifacts)
        if let debugInfoURL {
            logs.append(debugInfoURL)
        }
        logs.append(contentsOf: additionalLogs)
        return logs
    }

    private func embeddingMetricsLogURLs(since: Date?) -> [URL] {
        guard let directory = VoiceSessionDebugLogger.logsDirectoryURL() else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("voice-embedding-metrics-") else {
                return false
            }
            guard ["jsonl", "txt"].contains(url.pathExtension) else {
                return false
            }
            guard let since else { return true }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return modified >= since
        }
    }

    private func makeVoiceMonitorLog() -> String? {
        let lines = transcript.split(separator: "\n").map(String.init)
        var collected: [[String: Any]] = []
        for line in lines {
            if line.hasPrefix("Assistant:") {
                let text = line.replacingOccurrences(of: "Assistant:", with: "").trimmingCharacters(in: .whitespaces)
                collected.append(makeMonitorEvent(speaker: "assistant", kind: "assistant_text", text: text))
            } else if line.hasPrefix("You:") {
                let text = line.replacingOccurrences(of: "You:", with: "").trimmingCharacters(in: .whitespaces)
                collected.append(makeMonitorEvent(speaker: "user", kind: "user_text", text: text))
            } else if line.hasPrefix("System:") {
                let text = line.replacingOccurrences(of: "System:", with: "").trimmingCharacters(in: .whitespaces)
                collected.append(makeMonitorEvent(speaker: "system", kind: "system_text", text: text))
            }
        }
        let events = collected

        let assistantTexts = events.filter { ($0["speaker"] as? String) == "assistant" }
        let userTexts = events.filter { ($0["speaker"] as? String) == "user" }
        let systemTexts = events.filter { ($0["speaker"] as? String) == "system" }
        let assistantContent = assistantTexts.compactMap { $0["text"] as? String }

        let jsonMentions = assistantContent.filter { $0.lowercased().contains("json") }
        let confirmMentions = assistantContent.filter { $0.lowercased().contains("confirm") }
        var warnings: [String] = []
        if !jsonMentions.isEmpty {
            warnings.append("assistant_mentions_json")
        }
        if confirmMentions.count > 3 {
            warnings.append("too_many_confirm_prompts")
        }

        let analysis: [String: Any] = [
            "assistantLines": assistantTexts.count,
            "userLines": userTexts.count,
            "systemLines": systemTexts.count,
            "jsonMentionCount": jsonMentions.count,
            "confirmPromptCount": confirmMentions.count,
            "warnings": warnings
        ]

        let payload: [String: Any] = [
            "sessionStart": isoTimestamp(sessionStart ?? Date()),
            "events": events,
            "analysis": analysis
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return content
    }

    private func makeItemsSnapshotLog() -> String? {
        let items = store.items.filter { $0.type == .task || $0.type == .idea }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let payload = items.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "type": item.type.rawValue,
                "title": item.title,
                "details": item.details,
                "dueDate": item.dueDate.map { formatter.string(from: $0) } as Any,
                "tags": item.tags,
                "project": item.project as Any,
                "createdAt": isoTimestamp(item.createdAt)
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return content
    }

    /* Mock voice session helpers removed.
    @MainActor
    private func transcribeMockLineFromMic(
        text: String,
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        pitch: Float,
        speaker: String,
        onSpoken: @escaping () -> Void
    ) async {
        let utteranceIndex = mockUtteranceIndex
        mockUtteranceIndex += 1
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = rate
        utterance.pitchMultiplier = pitch

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if #available(iOS 13.0, *) {
            try? inputNode.setVoiceProcessingEnabled(false)
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let utteranceFileURL = VoiceSessionDebugLogger.logsDirectoryURL()?.appendingPathComponent(
            "voice-monitor-utterance-\(utteranceIndex)-\(UUID().uuidString.prefix(6)).caf"
        )
        let utteranceFile = utteranceFileURL.flatMap { try? AVAudioFile(forWriting: $0, settings: inputFormat.settings) }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
        let converter = targetFormat.flatMap { AVAudioConverter(from: inputFormat, to: $0) }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                if let url = self.mockMicRecordingURL, self.mockMicRecordingFile == nil {
                    self.mockMicRecordingFile = try? AVAudioFile(forWriting: url, settings: inputFormat.settings)
                }
                if let file = self.mockMicRecordingFile {
                    try? file.write(from: buffer)
                }
                if let utteranceFile {
                    try? utteranceFile.write(from: buffer)
                }
                guard let targetFormat, let converter else { return }
                let frameCapacity = AVAudioFrameCount(targetFormat.sampleRate / 10)
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                    return
                }
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                _ = error
            }
            try? engine.start()

            Task { @MainActor in
                await speakUtterance(utterance, onFinish: onSpoken)
                inputNode.removeTap(onBus: 0)
                engine.stop()
                continuation.resume()
            }
        }

        let selected: String
        let shouldRunChinese = containsChinese(text)
        if let utteranceFileURL {
            let contextualStrings = makeContextualStrings(from: text)
            let enTranscript = await recognizeFile(url: utteranceFileURL, locale: Locale(identifier: "en_US"), contextualStrings: contextualStrings)
            let zhTranscript = shouldRunChinese
                ? await recognizeFile(url: utteranceFileURL, locale: Locale(identifier: "zh_CN"), contextualStrings: contextualStrings)
                : nil
            selected = selectTranscript(enTranscript, zhTranscript, fallback: text, preferChinese: shouldRunChinese)
        } else {
            selected = text
        }
        mockVoiceMonitorEvents.append(SpokenEvent(timestamp: Date(), speaker: speaker, text: selected, source: "mic"))
    }

    private func selectTranscript(_ english: String?, _ chinese: String?, fallback: String, preferChinese: Bool) -> String {
        let zh = (chinese ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let en = (english ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if preferChinese, containsChinese(zh), chineseConfidence(zh) >= 0.3 {
            return zh
        }
        if en.count >= zh.count, !en.isEmpty {
            return en
        }
        if !zh.isEmpty {
            return zh
        }
        return fallback
    }

    private func chineseConfidence(_ text: String) -> Double {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        let chineseCount = scalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        return Double(chineseCount) / Double(scalars.count)
    }

    private func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
        }
    }

    private func makeContextualStrings(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .map { String($0) }
            .filter { $0.count > 1 }
        var results = [trimmed]
        results.append(contentsOf: words)
        return Array(results.prefix(40))
    }

    @MainActor
    private func recognizeFile(url: URL, locale: Locale, contextualStrings: [String]) async -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        if #available(iOS 13, *) {
            request.requiresOnDeviceRecognition = false
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var didResume = false
            let task = recognizer.recognitionTask(with: request) { result, _ in
                guard let result else { return }
                if result.isFinal, !didResume {
                    didResume = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !didResume {
                    didResume = true
                    continuation.resume(returning: nil)
                }
                task.cancel()
            }
        }
    }

    @MainActor
    private func speakLocalAssistant(_ text: String) async {
        let _ = text
    }

    @MainActor
    private func speakUtterance(_ utterance: AVSpeechUtterance, onFinish: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            let delegate = SpeechCompletionDelegate {
                onFinish()
                continuation.resume()
            }
            mockSpeechDelegate = delegate
            speechSynthesizer.delegate = delegate
            speechSynthesizer.speak(utterance)
        }
        mockSpeechDelegate = nil
        speechSynthesizer.delegate = nil
    }

    private func recordSpokenLine(prefix: String, text: String, source: String = "internal") {
        transcript = appendLine(transcript, prefix: prefix, text: text)
        let speaker = prefix.lowercased() == "you" ? "user" : "assistant"
        spokenEvents.append(SpokenEvent(timestamp: Date(), speaker: speaker, text: text, source: source))
    }

    private func prepareMockAudioSession() {
        let useSpeaker = UserDefaults.standard.object(forKey: "voiceSessionUseSpeaker") as? Bool ?? true
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.duckOthers, .allowBluetoothHFP]
        if useSpeaker {
            options.insert(.defaultToSpeaker)
        }
        try? session.setCategory(.playAndRecord, mode: .default, options: options)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        if useSpeaker {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    private func prepareMockMicRecording(sessionStart: Date) {
        guard mockMicAuthorized else {
            mockMicRecordingURL = nil
            mockMicRecordingFile = nil
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "voice-monitor-audio-\(formatter.string(from: sessionStart)).caf"
        guard let directory = VoiceSessionDebugLogger.logsDirectoryURL() else { return }
        mockMicRecordingURL = directory.appendingPathComponent(filename)
        mockMicRecordingFile = nil
    }

    private func mockUpScenarios(for scenarioID: MockUpScenarioID) -> [MockUpScenario] {
        let allScenarios: [MockUpScenario] = [
            MockUpScenario(
                title: "New task + confirm all",
                userUtterances: ["I need a reminder for my flight from SFO to PVG on Saturday at 1 pm."],
                assistantResponse: "Got it. I'll add that reminder.",
                proposalJSON: "{\"action\":\"create\",\"type\":\"task\",\"title\":\"Flight from SFO to PVG\",\"details\":\"Saturday 1 pm flight reminder\",\"priority\":\"normal\",\"dueDate\":null,\"project\":null,\"tags\":[] }",
                clearStore: true
            ),
            MockUpScenario(
                title: "Review + skip",
                userUtterances: ["Add an idea: plan a weekend hiking trip."],
                assistantResponse: "Sure. I'll capture that idea.",
                proposalJSON: "{\"action\":\"create\",\"type\":\"idea\",\"title\":\"Plan a weekend hiking trip\",\"details\":\"Pick a trail and pack list\",\"priority\":\"normal\",\"dueDate\":null,\"project\":null,\"tags\":[] }",
                clearStore: true
            ),
            MockUpScenario(
                title: "Similar item merge",
                userUtterances: ["Please remember to install OpenClaw at home soon."],
                assistantResponse: "Okay. I'll capture that.",
                proposalJSON: "{\"action\":\"create\",\"type\":\"idea\",\"title\":\"Install OpenClaw at home\",\"details\":\"Set up dependencies\",\"priority\":\"normal\",\"dueDate\":null,\"project\":null,\"tags\":[] }",
                existingItems: [
                    DraftItem(
                        type: .idea,
                        title: "Install OpenClaw at home",
                        details: "",
                        rawText: "Install OpenClaw at home",
                        priority: .normal,
                        dueDate: nil,
                        tags: [],
                        project: nil
                    )
                ],
                clearStore: true,
                applyProposal: false
            ),
            MockUpScenario(
                title: "Similar item new",
                userUtterances: ["I also want to install OpenClaw locally first."],
                assistantResponse: "Got it.",
                proposalJSON: "{\"action\":\"create\",\"type\":\"idea\",\"title\":\"Install OpenClaw locally\",\"details\":\"Try a local run\",\"priority\":\"normal\",\"dueDate\":null,\"project\":null,\"tags\":[] }",
                existingItems: [
                    DraftItem(
                        type: .idea,
                        title: "Install OpenClaw at home",
                        details: "",
                        rawText: "Install OpenClaw at home",
                        priority: .normal,
                        dueDate: nil,
                        tags: [],
                        project: nil
                    )
                ],
                clearStore: true,
                applyProposal: false
            )
        ]

        switch scenarioID {
        case .all:
            return allScenarios
        case .confirmAll:
            return [allScenarios[0]]
        case .reviewSkip:
            return [allScenarios[1]]
        case .merge:
            return [allScenarios[2]]
        case .newItem:
            return [allScenarios[3]]
        case .random:
            if let scenario = allScenarios.randomElement() {
                return [scenario]
            }
            return allScenarios
        }
    }

    private func resetMockScenarioState(clearStore: Bool) {
        if clearStore {
            let existingItems = store.items
            for item in existingItems {
                store.deleteItem(id: item.id)
            }
        }
    }

    */
    private func makeMonitorEvent(speaker: String, kind: String, text: String, timestamp: Date = Date(), source: String? = nil) -> [String: Any] {
        [
            "timestamp": isoTimestamp(timestamp),
            "speaker": speaker,
            "kind": kind,
            "text": text,
            "source": source as Any
        ]
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
        When the user gives a clear instruction, acknowledge and proceed without asking for confirmation. Only ask for "confirm" or "reject" if you are unsure or need approval.
        If the user says "just write it down" or indicates they do not want more details, stop follow-up questions and capture the item as a task.
        Do not output any JSON or structured metadata during the live conversation. The app will generate structured diffs after the session ends.
        Before responding to any new request, check whether it is similar to an existing inbox item.
        If it is similar, you must proactively point it out and ask whether to merge or keep it as a new item.
        Do not wait for the user to ask about duplicates.
        When you receive a list of possible similar items from the app, use it to decide whether to call out a duplicate.
        When summarizing, speak naturally without listing metadata fields like priority, due dates, or tags.
        When the user asks for more history (e.g., "last 6 months"), wait for additional context before continuing.
        """
    }

    private func findSimilarItem(for draft: DraftItem) -> Item? {
        let combined = [draft.title, draft.details].filter { !$0.isEmpty }.joined(separator: "\n")
        if let match = embeddingIndex.bestMatch(query: combined, items: store.items), match.score >= 0.75 {
            return match.item
        }
        let normalizedDraft = normalizeSimilarityText(draft.title)
        guard !normalizedDraft.isEmpty else { return nil }
        return store.items.first { item in
            let normalizedItem = normalizeSimilarityText(item.title)
            return isSimilarText(normalizedDraft, normalizedItem)
        }
    }

    private func normalizeSimilarityText(_ text: String) -> String {
        let lowered = text.lowercased()
        let filtered = lowered.filter { $0.isLetter || $0.isNumber || $0 == " " }
        return filtered.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSimilarText(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if lhs.contains(rhs) || rhs.contains(lhs) { return true }
        let lhsTokens = Set(lhs.split(separator: " "))
        let rhsTokens = Set(rhs.split(separator: " "))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }
        let intersection = lhsTokens.intersection(rhsTokens)
        if intersection.count >= 2 { return true }
        let overlap = Double(intersection.count) / Double(max(lhsTokens.count, rhsTokens.count))
        return overlap >= 0.5
    }

    private func isProposalMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("proposal") || lowered.contains("propos") || lowered.contains("json")
    }

    private func isProposalMarkerFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 6 else { return false }
        let compact = trimmed.lowercased().filter { $0.isLetter || $0 == "_" }
        guard !compact.isEmpty else { return false }
        if "proposal".hasPrefix(compact) || "proposal_json".hasPrefix(compact) || "propos".hasPrefix(compact) {
            return true
        }
        return compact == "json" || compact == "_json"
    }

    private func handleProposalCapture(_ text: String) {
        if proposalCaptureActive == false {
            let split = splitOnProposalMarker(text)
            let isFragment = split.remainder == nil && isProposalMarkerFragment(text)
            if !split.prefix.isEmpty, !isFragment {
                let cleanedPrefix = split.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedPrefix.isEmpty {
                    transcript = appendLine(transcript, prefix: "Assistant", text: cleanedPrefix)
                    latestAssistantText = cleanedPrefix
                }
            }
            proposalCaptureActive = true
            proposalCaptureStartedAt = Date()
            startProposalMute()
            if let remainder = split.remainder {
                proposalCaptureBuffer += remainder
            } else {
                proposalCaptureBuffer += text
            }
        } else {
            proposalCaptureBuffer += text
        }

        if let proposal = parseProposalFromBuffer(proposalCaptureBuffer) {
            pendingProposal = proposal
            if case .create(let draft) = proposal.action, handleDuplicateProposal(draft) {
                endProposalCapture(shouldPrompt: false)
                return
            }
            if shouldAutoApplyProposal(for: latestAssistantText ?? "") {
                lastConfirmTime = Date()
                applyPendingProposal(silent: true)
                endProposalCapture(shouldPrompt: false)
            } else {
                endProposalCapture(shouldPrompt: true)
            }
        } else if let startedAt = proposalCaptureStartedAt, Date().timeIntervalSince(startedAt) > 5 {
            endProposalCapture(shouldPrompt: true)
        }
    }

    private func splitOnProposalMarker(_ text: String) -> (prefix: String, remainder: String?) {
        let lowered = text.lowercased()
        if let range = lowered.range(of: "proposal") ?? lowered.range(of: "propos") {
            let prefix = String(text[..<range.lowerBound])
            let remainder = String(text[range.lowerBound...])
            return (prefix, remainder)
        }
        return (text, nil)
    }

    private func parseProposalFromBuffer(_ buffer: String) -> PendingProposal? {
        guard let startIndex = buffer.firstIndex(of: "{") else { return nil }
        guard let endIndex = buffer.lastIndex(of: "}") else { return nil }
        let jsonString = buffer[startIndex...endIndex]
        return parseProposal(from: String(jsonString))
    }

    private func startProposalMute() {
        suppressAudioPlayback = true
        audioService.stopPlayback()
        proposalMuteRetryTask?.cancel()
    }

    private func endProposalCapture(shouldPrompt: Bool) {
        proposalCaptureActive = false
        proposalCaptureBuffer = ""
        proposalCaptureStartedAt = nil
        proposalIgnoreUntil = Date().addingTimeInterval(2.0)
        proposalMuteTask?.cancel()
        proposalMuteRetryTask?.cancel()
        scheduleProposalUnmute()
        if shouldPrompt {
            sendProposalConfirmationPrompt()
        }
    }

    private func sendProposalConfirmationPrompt() {
        guard let provider else { return }
        Task {
            try? await provider.sendText("Please say confirm or reject.")
        }
    }

    private func scheduleProposalUnmute() {
        proposalMuteTask?.cancel()
        proposalMuteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                self?.attemptProposalUnmute()
            }
        }
    }

    private func attemptProposalUnmute() {
        let now = Date()
        let silenceWindow: TimeInterval = 1.2
        let hasRecentOutput = lastOutputPacketTime.map { now.timeIntervalSince($0) < silenceWindow } ?? false
        if hasRecentOutput {
            proposalMuteRetryTask?.cancel()
            proposalMuteRetryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run {
                    self?.attemptProposalUnmute()
                }
            }
            return
        }
        suppressAudioPlayback = false
        audioService.startPlayback()
    }

    private func appendLine(_ base: String, prefix: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        if prefix == "System" {
            return base
        }
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
        if value is NSNull {
            return nil
        }
        guard let dateString = value as? String, !dateString.isEmpty else {
            return nil
        }
        return DueDateParser.parse(dateString)
    }

    private func applyPendingProposal(silent: Bool) {
        guard let pendingProposal else {
            if !silent {
                transcript = appendLine(transcript, prefix: "System", text: "No pending proposal to apply.")
            }
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
        if !silent {
            transcript = appendLine(transcript, prefix: "System", text: "Applied proposal.")
        }
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

private enum SummaryPhase {
    case idle
    case spokenRequested
    case itemsRequested
}

private enum SummaryReviewPhase {
    case idle
    case awaitingNewDecision
    case awaitingNewConfirmAll
    case reviewingNew
    case awaitingNewItemConfirm
    case reviewingSimilar
    case awaitingSimilarMergeConfirm
    case awaitingSimilarNewConfirm
}

private struct SummaryReviewItem {
    let draft: DraftItem
    let similarItem: Item?
}

private enum SummaryReviewCommand {
    case confirmAll
    case confirm
    case merge
    case new
    case skip
    case repeatItem
    case details
    case next
    case stop
    case review
}

private struct EmbeddingMetricsCandidate: Codable {
    let id: String
    let type: String
    let title: String
    let details: String
    let project: String?
    let tags: [String]
    let createdAt: String
    let score: Double
}

private struct EmbeddingMetricsEntry: Codable {
    let timestamp: String
    let modelVersion: String
    let utterance: String
    let decision: String
    let candidates: [EmbeddingMetricsCandidate]
}

private struct PendingEmbeddingMetrics {
    let timestamp: Date
    let modelVersion: String
    let utterance: String
    let candidates: [EmbeddingMetricsCandidate]
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
