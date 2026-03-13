import SwiftUI

struct AddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ItemStore
    let initialType: ItemType

    // Form state.
    @State private var title = ""
    @State private var details = ""
    @State private var priority: ItemPriority = .normal
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var projectText = ""
    @State private var tagsText = ""

    init(store: ItemStore, initialType: ItemType = .note) {
        self.store = store
        self.initialType = initialType
    }

    var body: some View {
        NavigationStack {
            Form {
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
                        DatePicker("Due date", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    }
                    TextField("Project", text: $projectText)
                    TextField("Tags (comma separated)", text: $tagsText)
                }

            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Close without saving.
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        // Persist the new item and close.
                        saveItem()
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
    }

    private var isSaveDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var navigationTitle: String {
        switch initialType {
        case .task:
            return "New Task"
        case .idea:
            return "New Idea"
        case .note:
            return "New Note"
        }
    }

    private var saveButtonTitle: String {
        switch initialType {
        case .task:
            return "Save Task"
        case .idea:
            return "Save Idea"
        case .note:
            return "Save Note"
        }
    }

    private func saveItem() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawText = trimmedDetails.isEmpty ? trimmedTitle : trimmedDetails

        guard !rawText.isEmpty else { return }

        let resolvedTitle: String
        if !trimmedTitle.isEmpty {
            resolvedTitle = trimmedTitle
        } else if trimmedDetails.isEmpty {
            resolvedTitle = "Untitled"
        } else {
            resolvedTitle = String(trimmedDetails.prefix(40))
        }

        store.addItem(
            type: initialType,
            title: resolvedTitle,
            details: trimmedDetails,
            rawText: rawText,
            priority: priority,
            dueDate: hasDueDate ? dueDate : nil,
            tags: normalizedTags(from: tagsText),
            project: normalizedProject(from: projectText)
        )
        dismiss()
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

struct AddItemView_Previews: PreviewProvider {
    static var previews: some View {
        AddItemView(store: ItemStore(), initialType: .task)
    }
}
