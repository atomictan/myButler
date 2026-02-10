import SwiftUI

struct AddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ItemStore

    // Form state.
    @State private var title = ""
    @State private var details = ""
    @State private var type: ItemType = .note
    @State private var priority: ItemPriority = .normal
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var projectText = ""
    @State private var tagsText = ""
    @State private var isStructuring = false
    @State private var proposedDraft: StructuredDraft?
    @State private var proposedRawText = ""
    @State private var structuringError: String?
    @State private var isShowingProposedStructure = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    // Quick category selection.
                    Picker("Type", selection: $type) {
                        ForEach(ItemType.allCases) { itemType in
                            Text(itemType.rawValue.capitalized)
                                .tag(itemType)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Title") {
                    // Short summary for the list.
                    TextField("Short title", text: $title)
                }

                Section("Details") {
                    // Longer description or full note.
                    TextEditor(text: $details)
                        .frame(minHeight: 120)
                }

                Section("Metadata") {
                    Picker("Priority", selection: $priority) {
                        ForEach(ItemPriority.allCases) { itemPriority in
                            Text(itemPriority.label)
                                .tag(itemPriority)
                        }
                    }
                    Toggle("Has due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    }
                    TextField("Project", text: $projectText)
                    TextField("Tags (comma separated)", text: $tagsText)
                }

            }
            .navigationTitle("New Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Close without saving.
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Persist the new item and close.
                        startStructuring()
                    }
                    .disabled(isSaveDisabled || isStructuring)
                }
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

    private var isSaveDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startStructuring() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawText = trimmedDetails.isEmpty ? trimmedTitle : trimmedDetails

        guard !rawText.isEmpty else { return }

        isStructuring = true
        structuringError = nil
        proposedRawText = rawText

        Task {
            do {
                let service = StructuringService()
                var draft = try await service.structure(text: rawText)
                draft = StructuringParser.validate(draft)

                if !trimmedTitle.isEmpty {
                    draft.title = trimmedTitle
                }
                if !trimmedDetails.isEmpty {
                    draft.details = trimmedDetails
                }
                if type != .note {
                    draft.type = type
                }
                if priority != .normal {
                    draft.priority = priority
                }
                if hasDueDate {
                    draft.dueDate = dueDate
                }
                if let project = normalizedProject(from: projectText) {
                    draft.project = project
                }
                let tags = normalizedTags(from: tagsText)
                if !tags.isEmpty {
                    draft.tags = tags
                }

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

    private func normalizedTags(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedProject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    AddItemView(store: ItemStore())
}
