import SwiftUI

struct ItemDetailView: View {
    @Environment(\.dismiss) private var dismiss
    // Item to display in the detail screen.
    let item: Item
    @ObservedObject var store: ItemStore

    @State private var priority: ItemPriority
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var projectText: String
    @State private var tagsText: String
    @State private var detailsText: String
    @State private var titleText: String
    @State private var itemType: ItemType
    @State private var rawTextValue: String
    @State private var isCompleted: Bool
    @State private var isShowingDeleteConfirm = false

    init(item: Item, store: ItemStore) {
        self.item = item
        self.store = store
        _priority = State(initialValue: item.priority)
        _hasDueDate = State(initialValue: item.dueDate != nil)
        _dueDate = State(initialValue: item.dueDate ?? Date())
        _projectText = State(initialValue: item.project ?? "")
        _tagsText = State(initialValue: item.tags.joined(separator: ", "))
        _detailsText = State(initialValue: item.details)
        _titleText = State(initialValue: item.title)
        _itemType = State(initialValue: item.type)
        _rawTextValue = State(initialValue: item.rawText)
        _isCompleted = State(initialValue: item.isCompleted)
    }

    var body: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $titleText)
            }

            Section("Details") {
                TextEditor(text: $detailsText)
                    .frame(minHeight: 140)
            }

            Section("Raw Text") {
                TextEditor(text: $rawTextValue)
                    .frame(minHeight: 140)
            }

            Section("Metadata") {
                Toggle("Completed", isOn: $isCompleted)
                Picker("Type", selection: $itemType) {
                    ForEach(ItemType.allCases) { itemType in
                        Text(itemType.rawValue.capitalized)
                            .tag(itemType)
                    }
                }
                // Timestamp for when the item was captured.
                LabeledContent("Captured", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
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
        .navigationTitle("Item")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isShowingDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .onChange(of: priority) { _, _ in
            updateMetadata()
        }
        .onChange(of: hasDueDate) { _, _ in
            updateMetadata()
        }
        .onChange(of: dueDate) { _, _ in
            updateMetadata()
        }
        .onChange(of: projectText) { _, _ in
            updateMetadata()
        }
        .onChange(of: tagsText) { _, _ in
            updateMetadata()
        }
        .onChange(of: detailsText) { _, _ in
            updateDetails()
        }
        .onChange(of: titleText) { _, _ in
            updateTitle()
        }
        .onChange(of: itemType) { _, _ in
            updateType()
        }
        .onChange(of: isCompleted) { _, newValue in
            store.setCompletion(id: item.id, isCompleted: newValue)
        }
        .onChange(of: rawTextValue) { _, _ in
            updateRawText()
        }
        .alert("Delete Item", isPresented: $isShowingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                deleteItem()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func updateMetadata() {
        store.updateItem(id: item.id) { item in
            item.priority = priority
            item.dueDate = hasDueDate ? dueDate : nil
            item.project = normalizedProject(from: projectText)
            item.tags = normalizedTags(from: tagsText)
        }
    }

    private func updateDetails() {
        store.updateItem(id: item.id) { item in
            item.details = detailsText
        }
    }

    private func updateTitle() {
        store.updateItem(id: item.id) { item in
            item.title = titleText
        }
    }

    private func updateType() {
        store.updateItem(id: item.id) { item in
            item.type = itemType
        }
    }

    private func updateRawText() {
        store.updateItem(id: item.id) { item in
            item.rawText = rawTextValue
        }
    }

    private func deleteItem() {
        store.deleteItem(id: item.id)
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

struct ItemDetailView_Previews: PreviewProvider {
    static var previews: some View {
        ItemDetailView(item: Item(type: .note, title: "Sample", details: "Sample details"), store: ItemStore())
    }
}
