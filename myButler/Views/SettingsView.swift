import SwiftUI

struct SettingsView: View {
    @AppStorage("structuringProvider") private var structuringProvider = StructuringProviderKind.mock.rawValue
    @AppStorage("openAIAPIKey") private var openAIAPIKey = ""
    @AppStorage("openAIModel") private var openAIModel = "gpt-5.2"
    @AppStorage("doubaoAPIToken") private var doubaoAPIToken = ""
    @AppStorage("doubaoModel") private var doubaoModel = "doubao-seed-1-6-lite-251015"
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
        NavigationStack {
            Form {
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
                }
            }
            .navigationTitle("Settings")
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
    SettingsView()
}
