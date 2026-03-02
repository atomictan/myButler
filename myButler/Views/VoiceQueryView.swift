import AVFoundation
import SwiftUI

struct VoiceQueryView: View {
    @ObservedObject var store: ItemStore
    @StateObject private var captureService = VoiceCaptureService()

    @State private var queryText = ""
    @State private var isSummarizing = false
    @State private var summaryText: String?
    @State private var displayedSummary: String = ""
    @State private var summaryError: String?
    @State private var isSpeaking = false
    @State private var streamingTask: Task<Void, Never>?
    private let speechSynthesizer = AVSpeechSynthesizer()
    @State private var speechDelegate = SpeechDelegate()

    private var filteredItems: [Item] {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return store.items
        }

        let loweredQuery = trimmedQuery.lowercased()
        return store.items.filter { item in
            item.title.lowercased().contains(loweredQuery)
                || item.details.lowercased().contains(loweredQuery)
                || item.rawText.lowercased().contains(loweredQuery)
                || (item.project?.lowercased().contains(loweredQuery) ?? false)
                || item.tags.contains { $0.lowercased().contains(loweredQuery) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Query") {
                    TextEditor(text: $queryText)
                        .frame(minHeight: 100)
                    Button("Use Transcript") {
                        queryText = captureService.transcript
                    }
                    .disabled(captureService.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Transcript") {
                    if captureService.transcript.isEmpty {
                        Text("Start recording to capture a query.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(captureService.transcript)
                    }
                }

                Section("Results") {
                    if filteredItems.isEmpty {
                        Text("No matching items.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredItems) { item in
                            NavigationLink {
                                ItemDetailView(item: item, store: store)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                    if !item.details.isEmpty {
                                        Text(item.details)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(item.type.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 8) {
                                        Text(item.priority.label)
                                    if let dueDate = item.dueDate {
                                        Text("Due \(Item.dueDateDisplay(dueDate))")
                                    }
                                        if let project = item.project, !project.isEmpty {
                                            Text(project)
                                        }
                                        if !item.tags.isEmpty {
                                            Text(item.tags.joined(separator: ", "))
                                                .lineLimit(1)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                Section("AI Summary") {
                    if isSummarizing {
                        ProgressView("Summarizing...")
                    } else if summaryText != nil {
                        Text(displayedSummary)
                    } else {
                        Text("Ask for a summary of the matching items.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Summarize with AI") {
                        startSummarizing()
                    }
                    .disabled(isSummarizing)
                    HStack {
                        Button("Play") {
                            startSpeaking()
                        }
                        .disabled(displayedSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSpeaking)
                        Button("Stop") {
                            stopSpeaking()
                        }
                        .disabled(!isSpeaking)
                    }
                }
            }
            .navigationTitle("Voice")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: recordButtonIcon)
                    }
                    .disabled(!captureService.isAuthorized)
                }
            }
            .task {
                await captureService.requestPermissions()
            }
            .onAppear {
                speechSynthesizer.delegate = speechDelegate
                speechDelegate.onStop = {
                    isSpeaking = false
                }
            }
            .alert("Summary Failed", isPresented: Binding(
                get: { summaryError != nil },
                set: { _ in summaryError = nil }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(summaryError ?? "Unknown error")
            }
        }
    }

    private var recordButtonIcon: String {
        switch captureService.state {
        case .recording:
            return "stop.circle.fill"
        default:
            return "mic.circle.fill"
        }
    }

    private func toggleRecording() {
        if captureService.state == .recording {
            captureService.stopRecording()
        } else {
            captureService.startRecording()
        }
    }

    private func startSummarizing() {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuery = trimmedQuery.isEmpty ? "Summarize relevant items." : trimmedQuery
        guard !filteredItems.isEmpty else {
            summaryText = "No matching items to summarize."
            displayedSummary = summaryText ?? ""
            return
        }

        isSummarizing = true
        summaryError = nil
        summaryText = nil
        displayedSummary = ""
        streamingTask?.cancel()

        Task {
            do {
                let summary = try await QueryService().summarize(query: resolvedQuery, items: filteredItems)
                await MainActor.run {
                    summaryText = summary
                    startStreaming(text: summary)
                    isSummarizing = false
                }
            } catch {
                let message: String
                if case QueryError.unavailable(let name) = error {
                    message = name
                } else if case QueryError.invalidResponse(let details) = error {
                    message = details
                } else {
                    message = error.localizedDescription
                }
                await MainActor.run {
                    summaryError = message
                    isSummarizing = false
                }
            }
        }
    }

    private func startStreaming(text: String) {
        streamingTask?.cancel()
        displayedSummary = ""
        let words = text.split(separator: " ").map(String.init)

        streamingTask = Task { @MainActor in
            for (index, word) in words.enumerated() {
                if Task.isCancelled { return }
                displayedSummary += index == 0 ? word : " \(word)"
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func startSpeaking() {
        stopSpeaking()
        do {
            try configureSpeechSession()
        } catch {
            summaryError = error.localizedDescription
            return
        }
        let utterance = AVSpeechUtterance(string: displayedSummary)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        speechSynthesizer.speak(utterance)
        isSpeaking = true
    }

    private func stopSpeaking() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func configureSpeechSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.isOtherAudioPlaying {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}

final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onStop: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.onStop?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.onStop?()
        }
    }
}

#Preview {
    VoiceQueryView(store: ItemStore())
}
