import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @ObservedObject var store: ItemStore
    @AppStorage("structuringProvider") private var structuringProvider = StructuringProviderKind.mock.rawValue
    @AppStorage("openAIAPIKey") private var openAIAPIKey = ""
    @AppStorage("openAIModel") private var openAIModel = "gpt-5.2"
    @AppStorage("doubaoAPIToken") private var doubaoAPIToken = ""
    @AppStorage("doubaoModel") private var doubaoModel = "doubao-seed-1-8-251228"
    @AppStorage("doubaoDiffModel") private var doubaoDiffModel = "doubao-seed-2-0-mini-260215"
    @AppStorage("weeklyDigestRemindersEnabled") private var weeklyDigestRemindersEnabled = true
    @AppStorage("doubaoRealtimeAppId") private var doubaoRealtimeAppId = ""
    @AppStorage("doubaoRealtimeAppKey") private var doubaoRealtimeAppKey = ""
    @AppStorage("doubaoRealtimeAccessKey") private var doubaoRealtimeAccessKey = ""
    @AppStorage("voiceSessionASRSource") private var voiceSessionASRSource = "doubao"
    @AppStorage("voiceSessionUseSpeaker") private var voiceSessionUseSpeaker = true
    @AppStorage("voiceSessionEmbeddingDuplicatesEnabled") private var voiceSessionEmbeddingDuplicatesEnabled = true
    @AppStorage("voiceSessionEmbeddingMinScore") private var voiceSessionEmbeddingMinScore = 0.25
    @AppStorage("voiceSessionDebugEnabled") private var voiceSessionDebugEnabled = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    @AppStorage("voiceSessionDebugLoggingEnabled") private var voiceSessionDebugLoggingEnabled = false
    @AppStorage("weeklyDigestReminderWeekday") private var weeklyDigestReminderWeekday = 1
    @AppStorage("weeklyDigestReminderHour") private var weeklyDigestReminderHour = 18
    @AppStorage("weeklyDigestReminderMinute") private var weeklyDigestReminderMinute = 0
    @State private var isTestingConnection = false
    @State private var isTestingDoubaoConnection = false
    @State private var isPreparingShareLogs = false
    @State private var activeAlert: SettingsAlert?
    @State private var logsDebugInfoURL: URL?
    @State private var sharePayload: SharePayload?
    @State private var isShowingImportPicker = false
    @State private var isShowingImportOptions = false
    @State private var pendingImportURL: URL?

    private var providerSelection: Binding<StructuringProviderKind> {
        Binding(
            get: { StructuringProviderKind(rawValue: structuringProvider) ?? .mock },
            set: { structuringProvider = $0.rawValue }
        )
    }

    private var currentProvider: StructuringProviderKind {
        StructuringProviderKind(rawValue: structuringProvider) ?? .mock
    }

    @ViewBuilder
    private var providerSections: some View {
        AIProviderSection(providerSelection: providerSelection)
        if currentProvider == .openAI {
            OpenAISection(
                openAIAPIKey: $openAIAPIKey,
                openAIModel: $openAIModel,
                isTestingConnection: isTestingConnection,
                testConnection: testConnection
            )
        }
        if currentProvider == .doubao {
            DoubaoSection(
                doubaoAPIToken: $doubaoAPIToken,
                doubaoModel: $doubaoModel,
                doubaoDiffModel: $doubaoDiffModel,
                isTestingDoubaoConnection: isTestingDoubaoConnection,
                testDoubaoConnection: testDoubaoConnection
            )
            DoubaoRealtimeSection(
                doubaoRealtimeAppId: $doubaoRealtimeAppId,
                doubaoRealtimeAppKey: $doubaoRealtimeAppKey,
                doubaoRealtimeAccessKey: $doubaoRealtimeAccessKey
            )
        }
    }

    private var voiceSessionSectionView: some View {
        VoiceSessionSection(
            voiceSessionUseSpeaker: $voiceSessionUseSpeaker,
            voiceSessionASRSource: $voiceSessionASRSource,
            voiceSessionEmbeddingDuplicatesEnabled: $voiceSessionEmbeddingDuplicatesEnabled,
            voiceSessionEmbeddingMinScore: $voiceSessionEmbeddingMinScore,
            voiceSessionDebugEnabled: $voiceSessionDebugEnabled,
            voiceSessionDebugLoggingEnabled: $voiceSessionDebugLoggingEnabled,
            isPreparingShareLogs: $isPreparingShareLogs,
            logsDebugInfoURL: $logsDebugInfoURL,
            onDebugLogsInfo: {
                showAlert(title: "Logs Debug", message: VoiceSessionDebugLogger.debugInfoText())
            },
            onGenerateDebugInfoFile: { logsDebugInfoURL = VoiceSessionDebugLogger.writeDebugInfoFile() },
            onShareLatestLogs: shareLatestLogs
        )
    }

    private var settingsForm: some View {
        Form {
            WeeklyDigestSection(
                store: store,
                reminderLabel: reminderLabel,
                weeklyDigestRemindersEnabled: $weeklyDigestRemindersEnabled,
                weeklyDigestReminderWeekday: $weeklyDigestReminderWeekday,
                reminderTimeBinding: reminderTimeBinding,
                weekdayLabel: weekdayLabel(for:)
            )
            DeletedItemsSection(store: store)
            InboxExportSection(
                onExport: exportInbox,
                onImport: { isShowingImportPicker = true }
            )
            providerSections
            voiceSessionSectionView
        }
    }

    private var configuredBody: AnyView {
        AnyView(
            settingsForm
                .navigationTitle("Settings")
                .onChange(of: weeklyDigestRemindersEnabled) { _, newValue in
                    Task {
                        await WeeklyDigestReminder.updateSchedule(isEnabled: newValue, schedule: reminderSchedule)
                    }
                }
                .onChange(of: weeklyDigestReminderWeekday) { _, _ in
                    updateReminderSchedule()
                }
                .onChange(of: weeklyDigestReminderHour) { _, _ in
                    updateReminderSchedule()
                }
                .onChange(of: weeklyDigestReminderMinute) { _, _ in
                    updateReminderSchedule()
                }
                .overlay {
                    if isTestingConnection || isTestingDoubaoConnection {
                        ProgressView("Testing...")
                    }
                }
                .alert(item: $activeAlert) { alert in
                    Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .cancel()
                    )
                }
                .sheet(item: $sharePayload) { payload in
                    shareSheetView(for: payload)
                }
                .fileImporter(
                    isPresented: $isShowingImportPicker,
                    allowedContentTypes: [UTType.json],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        pendingImportURL = url
                        isShowingImportOptions = true
                    case .failure(let error):
                        showAlert(title: "Import Failed", message: error.localizedDescription)
                    }
                }
                .confirmationDialog("Import Inbox", isPresented: $isShowingImportOptions, titleVisibility: .visible) {
                    ForEach(InboxImportMode.allCases) { mode in
                        Button(mode.label) {
                            importInbox(mode: mode)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Choose how to apply the imported items.")
                }
        )
    }

    var body: some View {
        configuredBody
    }

    private func shareSheetView(for payload: SharePayload) -> some View {
        AppPerformanceLogger.shared.log("Share Latest Logs sheet presented")
        return ShareSheet(items: payload.items)
    }

    private var reminderSchedule: WeeklyDigestSchedule {
        WeeklyDigestSchedule(
            frequency: .weekly,
            weekday: weeklyDigestReminderWeekday,
            monthDay: 1,
            hour: weeklyDigestReminderHour,
            minute: weeklyDigestReminderMinute
        )
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = weeklyDigestReminderHour
                components.minute = weeklyDigestReminderMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                weeklyDigestReminderHour = components.hour ?? 18
                weeklyDigestReminderMinute = components.minute ?? 0
            }
        )
    }

    private func weekdayLabel(for value: Int) -> String {
        let calendar = Calendar.current
        let symbols = calendar.weekdaySymbols
        let index = max(1, min(7, value)) - 1
        return symbols[index]
    }

    private var reminderLabel: String {
        let timeString = reminderTimeBinding.wrappedValue.formatted(date: .omitted, time: .shortened)
        let dayName = weekdayLabel(for: weeklyDigestReminderWeekday)
        return "Reminder — Weekly, \(dayName) \(timeString)"
    }

    private func updateReminderSchedule() {
        guard weeklyDigestRemindersEnabled else { return }
        Task {
            await WeeklyDigestReminder.updateSchedule(isEnabled: true, schedule: reminderSchedule)
        }
    }


    private func testConnection() {
        isTestingConnection = true
        let apiKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await OpenAIConnectivityTester(apiKey: apiKey).testConnection()
                await MainActor.run {
                    showAlert(title: "Connection Test", message: "Connection successful.")
                    isTestingConnection = false
                }
            } catch {
                let message: String
                if case StructuringError.invalidResponse(let details) = error {
                    message = details
                } else {
                    message = error.localizedDescription
                }
                await MainActor.run {
                    showAlert(title: "Connection Test", message: message)
                    isTestingConnection = false
                }
            }
        }
    }

    private func testDoubaoConnection() {
        isTestingDoubaoConnection = true
        let apiToken = doubaoAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = doubaoModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.isEmpty ? "doubao-seed-1-8-251228" : model

        Task {
            do {
                try await DoubaoConnectivityTester(apiToken: apiToken, model: resolvedModel).testConnection()
                await MainActor.run {
                    showAlert(title: "Connection Test", message: "Connection successful.")
                    isTestingDoubaoConnection = false
                }
            } catch {
                let message: String
                if case StructuringError.invalidResponse(let details) = error {
                    message = details
                } else {
                    message = error.localizedDescription
                }
                await MainActor.run {
                    showAlert(title: "Connection Test", message: message)
                    isTestingDoubaoConnection = false
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        activeAlert = SettingsAlert(title: title, message: message)
    }

    private func shareLatestLogs() {
        let start = Date()
        AppPerformanceLogger.shared.log("Share Latest Logs tapped")
        var latestLogs = VoiceSessionDebugLogger.latestRunLogFiles()
        latestLogs.removeAll { $0.lastPathComponent == "app-performance.log" }
        guard !latestLogs.isEmpty || VoiceSessionDebugLogger.latestRunLogFiles().contains(where: { $0.lastPathComponent == "app-performance.log" }) else {
            showAlert(title: "Share Logs", message: "No recent voice session logs found yet.")
            AppPerformanceLogger.shared.log("Share Latest Logs aborted: no logs")
            return
        }
        isPreparingShareLogs = true
        Task.detached(priority: .userInitiated) {
            var exportedLogs = VoiceSessionDebugLogger.exportLogsForFileSharing(urls: latestLogs)
            let performanceSnapshot = await MainActor.run {
                AppPerformanceLogger.shared.snapshotForSharing(logging: "Share Latest Logs export completed")
            }
            if let performanceSnapshot {
                exportedLogs.append(contentsOf: VoiceSessionDebugLogger.exportLogsForFileSharing(urls: [performanceSnapshot]))
            }
            let finalExportedLogs = exportedLogs
            await MainActor.run {
                isPreparingShareLogs = false
                guard !finalExportedLogs.isEmpty else {
                    showAlert(title: "Share Logs", message: "Failed to export logs for sharing.")
                    AppPerformanceLogger.shared.mark("Share Latest Logs export failed", since: start)
                    return
                }
                AppPerformanceLogger.shared.mark("Share Latest Logs export", since: start)
                sharePayload = SharePayload(items: finalExportedLogs)
            }
        }
    }

    private func exportInbox() {
        do {
            let url = try store.exportInbox()
            sharePayload = SharePayload(items: [url])
        } catch {
            showAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func importInbox(mode: InboxImportMode) {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let result = try store.importInbox(from: url, mode: mode)
            showAlert(title: "Import Complete", message: "Inbox now has \(result.totalCount) items.")
        } catch {
            showAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct InboxExportSection: View {
    let onExport: () -> Void
    let onImport: () -> Void

    var body: some View {
        Section("Inbox Backup") {
            Button("Export Inbox") {
                onExport()
            }
            Button("Import Inbox") {
                onImport()
            }
            Text("Exports a JSON file you can email or re-import to recover your inbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WeeklyDigestSection: View {
    @ObservedObject var store: ItemStore
    let reminderLabel: String
    @Binding var weeklyDigestRemindersEnabled: Bool
    @Binding var weeklyDigestReminderWeekday: Int
    let reminderTimeBinding: Binding<Date>
    let weekdayLabel: (Int) -> String

    var body: some View {
        Section("Weekly Digest") {
            NavigationLink {
                WeeklyDigestView(store: store)
            } label: {
                Text("Weekly Digest")
            }
            Toggle(reminderLabel, isOn: $weeklyDigestRemindersEnabled)
            Picker("Day", selection: $weeklyDigestReminderWeekday) {
                ForEach(1...7, id: \.self) { day in
                    Text(weekdayLabel(day))
                        .tag(day)
                }
            }
            DatePicker("Time", selection: reminderTimeBinding, displayedComponents: .hourAndMinute)
            Text("You can disable this reminder anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DeletedItemsSection: View {
    @ObservedObject var store: ItemStore

    var body: some View {
        Section("Deleted Items") {
            NavigationLink {
                UndoHistoryView(store: store)
            } label: {
                HStack {
                    Text("Undo History")
                    Spacer()
                    if !store.deletedHistory.isEmpty {
                        Text("\(store.deletedHistory.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AIProviderSection: View {
    let providerSelection: Binding<StructuringProviderKind>

    var body: some View {
        Section("AI Provider") {
            Picker("Model", selection: providerSelection) {
                ForEach(StructuringProviderKind.allCases) { provider in
                    Text(provider.rawValue.capitalized)
                        .tag(provider)
                }
            }
        }
    }
}

private struct OpenAISection: View {
    @Binding var openAIAPIKey: String
    @Binding var openAIModel: String
    let isTestingConnection: Bool
    let testConnection: () -> Void

    var body: some View {
        Section("OpenAI") {
            SecureField("API Key", text: $openAIAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $openAIModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Menu("Model Presets") {
                Button("gpt-5.2") {
                    openAIModel = "gpt-5.2"
                }
            }
            Button("Test Connection") {
                testConnection()
            }
            .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)
        }
    }
}

private struct DoubaoSection: View {
    @Binding var doubaoAPIToken: String
    @Binding var doubaoModel: String
    @Binding var doubaoDiffModel: String
    let isTestingDoubaoConnection: Bool
    let testDoubaoConnection: () -> Void

    var body: some View {
        Section("Doubao") {
            SecureField("API Token", text: $doubaoAPIToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $doubaoModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Review Model", text: $doubaoDiffModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Menu("Model Presets") {
                Button("doubao-seed-2-0-pro-260215") {
                    doubaoModel = "doubao-seed-2-0-pro-260215"
                }
                Button("doubao-seed-2-0-mini-260215") {
                    doubaoModel = "doubao-seed-2-0-mini-260215"
                }
                Button("doubao-seed-1-6-251015") {
                    doubaoModel = "doubao-seed-1-6-251015"
                }
            }
            Menu("Review Model Presets") {
                Button("doubao-seed-2-0-mini-260215") {
                    doubaoDiffModel = "doubao-seed-2-0-mini-260215"
                }
                Button("doubao-seed-2-0-pro-260215") {
                    doubaoDiffModel = "doubao-seed-2-0-pro-260215"
                }
                Button("doubao-seed-1-6-lite-251015") {
                    doubaoDiffModel = "doubao-seed-1-6-lite-251015"
                }
            }
            Button("Use Main Model for Review") {
                doubaoDiffModel = doubaoModel
            }
            Text("Review Model is used for end-of-session diff generation. You can paste any future model ID here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Direct API tokens are for testing; use a backend proxy in production.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Test Connection") {
                testDoubaoConnection()
            }
            .disabled(doubaoAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingDoubaoConnection)
        }
    }
}

private struct DoubaoRealtimeSection: View {
    @Binding var doubaoRealtimeAppId: String
    @Binding var doubaoRealtimeAppKey: String
    @Binding var doubaoRealtimeAccessKey: String

    var body: some View {
        Section("Doubao Realtime") {
            TextField("App ID", text: $doubaoRealtimeAppId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("App Key", text: $doubaoRealtimeAppKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Access Key", text: $doubaoRealtimeAccessKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("These keys are required for realtime voice sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct VoiceSessionSection: View {
    @Binding var voiceSessionUseSpeaker: Bool
    @Binding var voiceSessionASRSource: String
    @Binding var voiceSessionEmbeddingDuplicatesEnabled: Bool
    @Binding var voiceSessionEmbeddingMinScore: Double
    @Binding var voiceSessionDebugEnabled: Bool
    @Binding var voiceSessionDebugLoggingEnabled: Bool
    @Binding var isPreparingShareLogs: Bool
    @Binding var logsDebugInfoURL: URL?
    let onDebugLogsInfo: () -> Void
    let onGenerateDebugInfoFile: () -> Void
    let onShareLatestLogs: () -> Void

    var body: some View {
        Section("Voice Session") {
            Toggle("Use Speaker Output", isOn: $voiceSessionUseSpeaker)
            Text("Routes voice sessions to the iPhone speaker instead of the receiver.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Transcript Source", selection: $voiceSessionASRSource) {
                Text("Doubao ASR").tag("doubao")
                Text("Local Speech").tag("local")
            }
            Text("Select how your voice is transcribed in Voice sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Embedding Duplicate Prompts", isOn: $voiceSessionEmbeddingDuplicatesEnabled)
            Text("Uses local embeddings to flag possible duplicates during the conversation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Embedding Min Score")
                Spacer()
                Text(String(format: "%.2f", voiceSessionEmbeddingMinScore))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $voiceSessionEmbeddingMinScore, in: 0.05...0.9, step: 0.05)
            Text("Raise this to reduce false positives; lower it to increase recall.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if DEBUG
            Toggle("Show Debug Meters", isOn: $voiceSessionDebugEnabled)
            Text("Shows mic/output levels and packet stats in Voice mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Save Debug Logs", isOn: $voiceSessionDebugLoggingEnabled)
            Text("Writes Voice session logs to iCloud Drive/MyButlerLogs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Share Latest Logs") {
                onShareLatestLogs()
            }
            .disabled(isPreparingShareLogs)
            if isPreparingShareLogs {
                ProgressView("Preparing logs…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Debug Logs Info") {
                onDebugLogsInfo()
            }
            Button("Generate Debug Info File") {
                onGenerateDebugInfoFile()
            }
            if let logsDebugInfoURL {
                ShareLink(item: logsDebugInfoURL) {
                    Label("Share Logs Debug Info", systemImage: "square.and.arrow.up")
                }
            }
            NavigationLink("View Voice Logs") {
                VoiceSessionLogsView()
            }
            #endif
        }
    }
}

struct SettingsScreen_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsScreen(store: ItemStore())
        }
    }
}
