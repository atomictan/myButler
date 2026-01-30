import SwiftUI

struct VoiceCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    // Shared store for saving the transcript as an item.
    @ObservedObject var store: ItemStore
    // Voice capture service that manages permissions + transcription.
    @StateObject private var captureService = VoiceCaptureService()
    @State private var isStructuring = false
    @State private var proposedDraft: StructuredDraft?
    @State private var proposedRawText = ""
    @State private var structuringError: String?
    @State private var isShowingProposedStructure = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusCard

                transcriptCard

                recordButton
            }
            .padding()
            .navigationTitle("Voice Capture")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        // Dismiss without saving.
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Save the transcript as a new inbox item.
                        startStructuring()
                    }
                    .disabled(isSaveDisabled || isStructuring)
                }
            }
            .task {
                // Ensure permissions are requested when the view appears.
                await captureService.requestPermissions()
            }
        }
        .overlay {
            if isStructuring {
                ProgressView("Structuring...")
            }
        }
        .sheet(isPresented: $isShowingProposedStructure) {
            if let proposedDraft {
                ProposedStructureView(
                    draft: proposedDraft,
                    rawText: proposedRawText,
                    store: store
                ) {
                    dismiss()
                }
            }
        }
        .alert("Structuring Failed", isPresented: Binding(
            get: { structuringError != nil },
            set: { _ in structuringError = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(structuringError ?? "Unknown error")
        }
    }

    // Displays current recording/transcription status.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.headline)
            Text(statusText)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // Shows the live transcript as the user speaks.
    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)
            if captureService.transcript.isEmpty {
                Text("Start recording to see the transcript.")
                    .foregroundStyle(.secondary)
            } else {
                Text(captureService.transcript)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }


    // Main record/stop button based on current state.
    private var recordButton: some View {
        Button {
            toggleRecording()
        } label: {
            Label(recordButtonTitle, systemImage: recordButtonIcon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!captureService.isAuthorized)
    }

    // Maps state to user-facing status text.
    private var statusText: String {
        switch captureService.state {
        case .idle:
            return captureService.isAuthorized ? "Ready to record." : "Waiting for permissions."
        case .recording:
            return "Recording..."
        case .transcribing:
            return "Transcribing audio..."
        case .failed(let message):
            return message
        }
    }

    // Derives the record button title from the state.
    private var recordButtonTitle: String {
        switch captureService.state {
        case .recording:
            return "Stop Recording"
        default:
            return "Start Recording"
        }
    }

    // Derives the record button icon from the state.
    private var recordButtonIcon: String {
        switch captureService.state {
        case .recording:
            return "stop.circle.fill"
        default:
            return "mic.circle.fill"
        }
    }

    // Starts or stops the voice capture flow.
    private func toggleRecording() {
        if captureService.state == .recording {
            captureService.stopRecording()
        } else {
            captureService.startRecording()
        }
    }

    private var isSaveDisabled: Bool {
        captureService.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startStructuring() {
        let trimmedTranscript = captureService.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }

        isStructuring = true
        structuringError = nil
        proposedRawText = trimmedTranscript

        Task {
            do {
                let service = StructuringService()
                var draft = try await service.structure(text: trimmedTranscript)
                draft = StructuringParser.validate(draft)

                await MainActor.run {
                    proposedDraft = draft
                    isShowingProposedStructure = true
                    isStructuring = false
                }
            } catch {
                let message: String
                if case StructuringError.unavailable(let name) = error {
                    message = "\(name)."
                } else if case StructuringError.invalidResponse(let details) = error {
                    message = details
                } else {
                    message = error.localizedDescription
                }
                await MainActor.run {
                    structuringError = message
                    isStructuring = false
                }
            }
        }
    }
}

#Preview {
    VoiceCaptureView(store: ItemStore())
}
