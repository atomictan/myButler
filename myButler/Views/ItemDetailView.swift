import SwiftUI

struct ItemDetailView: View {
    // Item to display in the detail screen.
    let item: Item
    @ObservedObject var store: ItemStore

    @State private var priority: ItemPriority
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var tagsText: String

    init(item: Item, store: ItemStore) {
        self.item = item
        self.store = store
        _priority = State(initialValue: item.priority)
        _hasDueDate = State(initialValue: item.dueDate != nil)
        _dueDate = State(initialValue: item.dueDate ?? Date())
        _tagsText = State(initialValue: item.tags.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("Title") {
                // Primary title for the item.
                Text(item.title)
                    .font(.headline)
            }

            Section("Details") {
                if item.details.isEmpty {
                    // Placeholder if no details were provided.
                    Text("No details yet")
                        .foregroundStyle(.secondary)
                } else {
                    // Full notes captured for the item.
                    Text(item.details)
                }
            }

            Section("Metadata") {
                // Category tag so users know the item type.
                LabeledContent("Type", value: item.type.rawValue.capitalized)
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
                    DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                }
                TextField("Tags (comma separated)", text: $tagsText)
            }
        }
        .navigationTitle("Item")
        .onChange(of: priority) { _, _ in
            updateMetadata()
        }
        .onChange(of: hasDueDate) { _, _ in
            updateMetadata()
        }
        .onChange(of: dueDate) { _, _ in
            updateMetadata()
        }
        .onChange(of: tagsText) { _, _ in
            updateMetadata()
        }
    }

    private func updateMetadata() {
        store.updateItem(id: item.id) { item in
            item.priority = priority
            item.dueDate = hasDueDate ? dueDate : nil
            item.tags = normalizedTags(from: tagsText)
        }
    }

    private func normalizedTags(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    ItemDetailView(item: Item(type: .note, title: "Sample", details: "Sample details"), store: ItemStore())
}
