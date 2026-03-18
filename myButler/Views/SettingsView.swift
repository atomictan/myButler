import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ItemStore
    @AppStorage("uiTheme") private var uiTheme = UITheme.classicBlue.rawValue
    @AppStorage("structuringProvider") private var structuringProvider = StructuringProviderKind.mock.rawValue
    @AppStorage("openAIAPIKey") private var openAIAPIKey = ""
    @AppStorage("openAIModel") private var openAIModel = "gpt-5.2"
    @AppStorage("doubaoAPIToken") private var doubaoAPIToken = ""
    @AppStorage("doubaoModel") private var doubaoModel = "doubao-seed-2-0-mini-260215"
    @AppStorage("doubaoDiffModel") private var doubaoDiffModel = "doubao-seed-2-0-mini-260215"
    @AppStorage("weeklyDigestRemindersEnabled") private var weeklyDigestRemindersEnabled = true
    @AppStorage("doubaoRealtimeAppId") private var doubaoRealtimeAppId = ""
    @AppStorage("doubaoRealtimeAccessKey") private var doubaoRealtimeAccessKey = ""
    @AppStorage("voiceSessionASRSource") private var voiceSessionASRSource = "doubao"
    @AppStorage("voiceSessionUseSpeaker") private var voiceSessionUseSpeaker = true
    @AppStorage("voiceSessionDebugLoggingEnabled") private var voiceSessionDebugLoggingEnabled = false
    @AppStorage("voiceSessionDebugEnabled") private var voiceSessionDebugEnabled = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    @AppStorage("weeklyDigestReminderWeekday") private var weeklyDigestReminderWeekday = 1
    @AppStorage("weeklyDigestReminderHour") private var weeklyDigestReminderHour = 18
    @AppStorage("weeklyDigestReminderMinute") private var weeklyDigestReminderMinute = 0
    @State private var isTestingConnection = false
    @State private var isTestingDoubaoConnection = false
    @State private var isPreparingShareLogs = false
    @State private var testResultMessage: String?
    @State private var shareAlertMessage: String?
    @State private var sharePayload: SharePayload?

    private var providerSelection: Binding<StructuringProviderKind> {
        Binding(
            get: { StructuringProviderKind(rawValue: structuringProvider) ?? .mock },
            set: { structuringProvider = $0.rawValue }
        )
    }

    @ViewBuilder
    private var appearanceSectionView: some View {
        Section("Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                Text("App Color Theme")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 12) {
                    ForEach(UITheme.allCases) { theme in
                        Button {
                            uiTheme = theme.rawValue
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(theme.secondaryColor)
                                        .frame(width: 44, height: 44)
                                    Circle()
                                        .fill(theme.tintColor)
                                        .frame(width: 26, height: 26)
                                    if selectedTheme == theme {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white, theme.tintColor)
                                            .offset(x: 15, y: -15)
                                    }
                                }
                                Text(theme.label)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Changes the accent color used across tabs, buttons, toggles, and highlights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var weeklyDigestSectionView: some View {
        Section("Weekly Digest") {
            NavigationLink {
                WeeklyDigestView(store: store)
            } label: {
                Text("Weekly Digest")
            }
            Toggle(reminderLabel, isOn: $weeklyDigestRemindersEnabled)
            Picker("Day", selection: $weeklyDigestReminderWeekday) {
                ForEach(1...7, id: \.self) { day in
                    Text(weekdayLabel(for: day))
                        .tag(day)
                }
            }
            DatePicker("Time", selection: reminderTimeBinding, displayedComponents: .hourAndMinute)
            Text("You can disable this reminder anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var deletedItemsSectionView: some View {
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

    @ViewBuilder
    private var providerSections: some View {
        Section("AI Provider") {
            Picker("Model", selection: providerSelection) {
                ForEach(StructuringProviderKind.allCases) { provider in
                    Text(provider.rawValue.capitalized)
                        .tag(provider)
                }
            }
        }
        if providerSelection.wrappedValue == .openAI {
            openAISectionView
        }
        if providerSelection.wrappedValue == .doubao {
            doubaoSectionView
            doubaoRealtimeSectionView
        }
    }

    private var openAISectionView: some View {
        Section("OpenAI") {
            SecureField("API Key", text: $openAIAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $openAIModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Test Connection") {
                testConnection()
            }
            .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)
        }
    }

    private var doubaoSectionView: some View {
        let modelPresets = [
            "doubao-seed-2-0-mini-260215",
            "doubao-seed-2-0-pro-260215",
            "doubao-seed-1-8-251228",
            "doubao-seed-1-6-lite-251015"
        ]
        return Section("Doubao") {
            SecureField("API Token", text: $doubaoAPIToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $doubaoModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Preset", selection: $doubaoModel) {
                ForEach(modelPresets, id: \.self) { preset in
                    Text(preset).tag(preset)
                }
            }
            TextField("Review Model", text: $doubaoDiffModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Review Preset", selection: $doubaoDiffModel) {
                ForEach(modelPresets, id: \.self) { preset in
                    Text(preset).tag(preset)
                }
            }
            Button("Use Main Model for Review") {
                doubaoDiffModel = doubaoModel
            }
            Text("Review Model is used for end-of-session diff generation. You can type any new model ID here when faster models become available.")
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

    private var doubaoRealtimeSectionView: some View {
        Section("Doubao Realtime") {
            TextField("App ID", text: $doubaoRealtimeAppId)
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

    @ViewBuilder
    private var voiceSessionSections: some View {
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
            #if DEBUG
            Toggle("Show Debug Meters", isOn: $voiceSessionDebugEnabled)
            Text("Shows mic/output levels and packet stats in Voice mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }

        Section("Voice Session Debug") {
            Toggle("Save Debug Logs", isOn: $voiceSessionDebugLoggingEnabled)
            Text("Enable this before a session to capture logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Share Latest Logs") {
                shareLatestLogs()
            }
            .disabled(isPreparingShareLogs)
            if isPreparingShareLogs {
                ProgressView("Preparing logs…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsForm: some View {
        Form {
            appearanceSectionView
            weeklyDigestSectionView
            deletedItemsSectionView
            providerSections
            voiceSessionSections
        }
    }

    private var connectionTestAlertBinding: Binding<Bool> {
        Binding(
            get: { testResultMessage != nil },
            set: { _ in testResultMessage = nil }
        )
    }

    private var shareLogsAlertBinding: Binding<Bool> {
        Binding(
            get: { shareAlertMessage != nil },
            set: { _ in shareAlertMessage = nil }
        )
    }

    private var baseSettingsView: AnyView {
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
        )
    }

    private var loadingOverlayView: AnyView {
        AnyView(
            baseSettingsView
                .overlay {
                    if isTestingConnection || isTestingDoubaoConnection {
                        ProgressView("Testing...")
                    }
                }
        )
    }

    private var configuredBody: AnyView {
        AnyView(
            loadingOverlayView
                .alert("Connection Test", isPresented: connectionTestAlertBinding) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(testResultMessage ?? "")
                }
                .alert("Share Logs", isPresented: shareLogsAlertBinding) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(shareAlertMessage ?? "")
                }
                .sheet(item: $sharePayload) { payload in
                    shareSheetView(for: payload)
                }
        )
    }

    var body: some View {
        configuredBody
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

    private var selectedTheme: UITheme {
        UITheme(rawValue: uiTheme) ?? .classicBlue
    }

    private func shareLatestLogs() {
        let start = Date()
        AppPerformanceLogger.shared.log("Share Latest Logs tapped")
        var latestLogs = VoiceSessionDebugLogger.latestRunLogFiles()
        latestLogs.removeAll { $0.lastPathComponent == "app-performance.log" }
        guard !latestLogs.isEmpty || VoiceSessionDebugLogger.latestRunLogFiles().contains(where: { $0.lastPathComponent == "app-performance.log" }) else {
            shareAlertMessage = "No recent voice session logs found yet."
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
                    shareAlertMessage = "Failed to export logs for sharing."
                    AppPerformanceLogger.shared.mark("Share Latest Logs export failed", since: start)
                    return
                }
                AppPerformanceLogger.shared.mark("Share Latest Logs export", since: start)
                sharePayload = SharePayload(items: finalExportedLogs)
            }
        }
    }

    private func shareSheetView(for payload: SharePayload) -> some View {
        AppPerformanceLogger.shared.log("Share Latest Logs sheet presented")
        return ShareSheet(items: payload.items)
    }

    private func testConnection() {
        isTestingConnection = true
        let apiKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await OpenAIConnectivityTester(apiKey: apiKey).testConnection()
                await MainActor.run {
                    testResultMessage = "Connection successful."
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
                    testResultMessage = message
                    isTestingConnection = false
                }
            }
        }
    }

    private func testDoubaoConnection() {
        isTestingDoubaoConnection = true
        let apiToken = doubaoAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = doubaoModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.isEmpty ? "doubao-seed-2-0-mini-260215" : model

        Task {
            do {
                try await DoubaoConnectivityTester(apiToken: apiToken, model: resolvedModel).testConnection()
                await MainActor.run {
                    testResultMessage = "Connection successful."
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
                    testResultMessage = message
                    isTestingDoubaoConnection = false
                }
            }
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

private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsView(store: ItemStore())
        }
    }
}
