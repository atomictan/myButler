import SwiftUI

struct VoiceSessionView: View {
    @ObservedObject var store: ItemStore
    @StateObject private var viewModel: VoiceSessionViewModel
    @AppStorage("voiceSessionDebugEnabled") private var voiceSessionDebugEnabled = false
    @AppStorage("voiceSessionUseSpeaker") private var voiceSessionUseSpeaker = true

    init(store: ItemStore) {
        self.store = store
        _viewModel = StateObject(wrappedValue: VoiceSessionViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusCard
                transcriptCard
                Button(action: toggleSession) {
                    Label(viewModel.isActive ? "End" : "Start", systemImage: viewModel.isActive ? "stop.circle.fill" : "waveform.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Voice")
            .onChange(of: voiceSessionUseSpeaker) { _, newValue in
                viewModel.updateSpeakerRouting(useSpeaker: newValue)
            }
            .alert("Voice Session", isPresented: $viewModel.isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.headline)
            Text(viewModel.statusText)
                .foregroundStyle(.secondary)
            Toggle("Speaker Output", isOn: $voiceSessionUseSpeaker)
            #if DEBUG
            if voiceSessionDebugEnabled {
                HStack {
                    Text("Mic level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: viewModel.inputLevel)
                        .tint(.green)
                }
                HStack {
                    Text("Output level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: viewModel.outputLevel)
                        .tint(.blue)
                }
                Text("Audio chunks: in \(viewModel.inputChunkCount) · out \(viewModel.outputChunkCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Last packet: in \(formatTime(viewModel.lastInputPacketTime)) · out \(formatTime(viewModel.lastOutputPacketTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Packet age: in \(formatAge(viewModel.lastInputPacketTime)) · out \(formatAge(viewModel.lastOutputPacketTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Recent bytes: in \(formatSizes(viewModel.recentInputPacketSizes)) · out \(formatSizes(viewModel.recentOutputPacketSizes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatAge(_ date: Date?) -> String {
        guard let date else { return "—" }
        let age = Date().timeIntervalSince(date)
        return String(format: "%.1fs", age)
    }

    private func formatSizes(_ sizes: [Int]) -> String {
        guard !sizes.isEmpty else { return "—" }
        return sizes.map(String.init).joined(separator: ", ")
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)
            if viewModel.transcript.isEmpty {
                Text("Start a session to begin the conversation.")
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.transcript)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func toggleSession() {
        if viewModel.isActive {
            viewModel.stopSession()
        } else {
            viewModel.startSession()
        }
    }
}

#Preview {
    VoiceSessionView(store: ItemStore())
}
