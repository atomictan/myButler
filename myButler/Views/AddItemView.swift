import SwiftUI

struct AddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ItemStore

    // Form state.
    @State private var title = ""
    @State private var details = ""
    @State private var type: ItemType = .note

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
                        saveItem()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // Normalizes the inputs and creates a new item.
    private func saveItem() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String

        // Choose a sensible title if the user left it blank.
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
            // Raw text preserves the original input.
            rawText: trimmedDetails.isEmpty ? trimmedTitle : trimmedDetails
        )
    }
}

#Preview {
    AddItemView(store: ItemStore())
}
