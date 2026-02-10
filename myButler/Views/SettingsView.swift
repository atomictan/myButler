import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ItemStore
    @AppStorage("structuringProvider") private var structuringProvider = StructuringProviderKind.mock.rawValue
    @AppStorage("openAIAPIKey") private var openAIAPIKey = ""
    @AppStorage("openAIModel") private var openAIModel = "gpt-5.2"
    @AppStorage("doubaoAPIToken") private var doubaoAPIToken = ""
    @AppStorage("doubaoModel") private var doubaoModel = "doubao-seed-1-6-lite-251015"
    @AppStorage("weeklyDigestRemindersEnabled") private var weeklyDigestRemindersEnabled = true
    @AppStorage("doubaoRealtimeAppId") private var doubaoRealtimeAppId = ""
    @AppStorage("doubaoRealtimeAccessKey") private var doubaoRealtimeAccessKey = ""
    @AppStorage("voiceSessionASRSource") private var voiceSessionASRSource = "doubao"
    @AppStorage("voiceSessionUseSpeaker") private var voiceSessionUseSpeaker = true
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
    @State private var testResultMessage: String?

    private var providerSelection: Binding<StructuringProviderKind> {
        Binding(
            get: { StructuringProviderKind(rawValue: structuringProvider) ?? .mock },
            set: { structuringProvider = $0.rawValue }
        )
    }

    var body: some View {
        Form {
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

            Section("AI Provider") {
                Picker("Model", selection: providerSelection) {
                    ForEach(StructuringProviderKind.allCases) { provider in
                        Text(provider.rawValue.capitalized)
                            .tag(provider)
                    }
                }
            }
            if providerSelection.wrappedValue == .openAI {
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

            if providerSelection.wrappedValue == .doubao {
                Section("Doubao") {
                    SecureField("API Token", text: $doubaoAPIToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model", text: $doubaoModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Direct API tokens are for testing; use a backend proxy in production.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Test Connection") {
                        testDoubaoConnection()
                    }
                    .disabled(doubaoAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingDoubaoConnection)
                }

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
        }
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
        .alert("Connection Test", isPresented: Binding(
            get: { testResultMessage != nil },
            set: { _ in testResultMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(testResultMessage ?? "")
        }
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
        let resolvedModel = model.isEmpty ? "doubao-seed-1-6-lite-251015" : model

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

#Preview {
    NavigationStack {
        SettingsView(store: ItemStore())
    }
}
