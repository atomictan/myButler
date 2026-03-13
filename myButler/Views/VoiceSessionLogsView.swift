import SwiftUI

struct VoiceSessionLogsView: View {
    @State private var logFiles: [URL] = []

    var body: some View {
        List {
            if logFiles.isEmpty {
                Text("No logs found yet. Run a voice session with logging enabled.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logFiles, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                        Text(url.deletingLastPathComponent().lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ShareLink(item: url) {
                            Label("Share Log", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .navigationTitle("Voice Logs")
        .toolbar {
            Button("Refresh") {
                loadLogs()
            }
        }
        .onAppear {
            loadLogs()
        }
    }

    private func loadLogs() {
        logFiles = VoiceSessionDebugLogger.listLogFiles()
    }
}

struct VoiceSessionLogsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            VoiceSessionLogsView()
        }
    }
}
