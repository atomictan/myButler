import SwiftUI

struct ProposedStructureView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ItemStore
    let rawText: String
    let onComplete: () -> Void

    @State private var type: ItemType
    @State private var title: String
    @State private var details: String
    @State private var priority: ItemPriority
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var tagsText: String

    init(draft: StructuredDraft, rawText: String, store: ItemStore, onComplete: @escaping () -> Void) {
        self.store = store
        self.rawText = rawText
        self.onComplete = onComplete
        _type = State(initialValue: draft.type)
        _title = State(initialValue: draft.title)
        _details = State(initialValue: draft.details)
        _priority = State(initialValue: draft.priority)
        _hasDueDate = State(initialValue: draft.dueDate != nil)
        _dueDate = State(initialValue: draft.dueDate ?? Date())
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Proposed Structure") {
                    Picker("Type", selection: $type) {
                        ForEach(ItemType.allCases) { itemType in
                            Text(itemType.rawValue.capitalized)
                                .tag(itemType)
                        }
                    }
                    TextField("Title", text: $title)
                }

                Section("Details") {
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
                    TextField("Tags (comma separated)", text: $tagsText)
                }
            }
            .navigationTitle("Proposed Structure")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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

    private func saveItem() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String

        if !trimmedTitle.isEmpty {
            resolvedTitle = trimmedTitle
        } else if trimmedDetails.isEmpty {
            resolvedTitle = "Untitled"
        } else {
            resolvedTitle = String(trimmedDetails.prefix(40))
        }

        store.addItem(
            type: type,
            title: resolvedTitle,
            details: trimmedDetails,
            rawText: rawText,
            priority: priority,
            dueDate: hasDueDate ? dueDate : nil,
            tags: normalizedTags(from: tagsText)
        )
        onComplete()
        dismiss()
    }

    private func normalizedTags(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    ProposedStructureView(
        draft: StructuredDraft(title: "Sample", details: "Sample details"),
        rawText: "Sample details",
        store: ItemStore(),
        onComplete: {}
    )
}
