import SwiftUI

enum InboxSortOption: String, CaseIterable, Identifiable {
    case created
    case priority
    case dueDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .created:
            return "Newest"
        case .priority:
            return "Priority"
        case .dueDate:
            return "Due Date"
        }
    }
}

enum InboxFilterOption: String, CaseIterable, Identifiable {
    case task
    case idea
    case note

    var id: String { rawValue }

    var label: String {
        switch self {
        case .task:
            return "To Do"
        case .idea:
            return "Ideas"
        case .note:
            return "Notes"
        }
    }

    var itemType: ItemType {
        switch self {
        case .task:
            return .task
        case .idea:
            return .idea
        case .note:
            return .note
        }
    }
}

struct InboxView: View {
    @ObservedObject var store: ItemStore
    @State private var isShowingAdd = false
    @State private var isShowingVoiceCapture = false
    @State private var sortOption: InboxSortOption = .created
    @State private var filterOption: InboxFilterOption = .task
    @State private var showCompleted = false
    @State private var editingDueDateItem: Item?
    @State private var editingDueDate = Date()

    private var sortedItems: [Item] {
        switch sortOption {
        case .created:
            return store.items.sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted
                }
                return lhs.createdAt > rhs.createdAt
            }
        case .priority:
            return store.items.sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted
                }
                if lhs.priority != rhs.priority {
                    return lhs.priority.rawValue > rhs.priority.rawValue
                }
                return lhs.createdAt > rhs.createdAt
            }
        case .dueDate:
            return store.items.sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted
                }
                let lhsDate = lhs.dueDate ?? Date.distantFuture
                let rhsDate = rhs.dueDate ?? Date.distantFuture
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return lhs.createdAt > rhs.createdAt
            }
        }
    }

    private var filteredItems: [Item] {
        sortedItems.filter {
            $0.type == filterOption.itemType && (showCompleted || !$0.isCompleted)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    // Empty-state placeholder when there are no items.
                    ContentUnavailableView("No items yet", systemImage: "tray")
                } else {
                    List {
                        Section {
                            Picker("Filter", selection: $filterOption) {
                                ForEach(InboxFilterOption.allCases) { option in
                                    Text(option.label)
                                        .tag(option)
                                }
                            }
                            .pickerStyle(.segmented)

                            Toggle("Show Completed", isOn: $showCompleted)
                        }

                        ForEach(filteredItems) { item in
                            NavigationLink {
                                ItemDetailView(item: item, store: store)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Button {
                                        store.toggleCompletion(id: item.id)
                                    } label: {
                                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(item.isCompleted ? .green : .secondary)
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(.headline)
                                            .strikethrough(item.isCompleted)
                                            .foregroundStyle(item.isCompleted ? .secondary : .primary)
                                        if !item.details.isEmpty {
                                            Text(item.details)
                                                .font(.subheadline)
                                                .strikethrough(item.isCompleted)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(item.type.rawValue.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack(spacing: 8) {
                                            if item.isCompleted {
                                                Text("Completed")
                                            }
                                            Text(item.priority.label)
                                            if let dueDate = item.dueDate {
                                                Text("Due \(Item.dueDateDisplay(dueDate))")
                                            }
                                            if isExpired(item) {
                                                Button("Expired") {
                                                    beginDueDateEdit(for: item)
                                                }
                                                .buttonStyle(.bordered)
                                                .tint(.red)
                                            }
                                            if let project = item.project, !project.isEmpty {
                                                Text(project)
                                            }
                                            if !item.tags.isEmpty {
                                                Text(item.tags.joined(separator: ", "))
                                                    .lineLimit(1)
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: deleteItems)
                    }
                    .themedScrollableBackground()
                }
            }
            .navigationTitle("Inbox")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Opens the add-item modal.
                        isShowingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Opens the voice capture sheet.
                        isShowingVoiceCapture = true
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: $sortOption) {
                            ForEach(InboxSortOption.allCases) { option in
                                Text(option.label)
                                    .tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            // Presents the add form.
            .sheet(isPresented: $isShowingAdd) {
                AddItemView(store: store, initialType: filterOption.itemType)
            }
            // Presents the voice capture flow.
            .sheet(isPresented: $isShowingVoiceCapture) {
                VoiceCaptureView(store: store)
            }
            .sheet(item: $editingDueDateItem) { item in
                DueDateEditSheet(
                    item: item,
                    dueDate: $editingDueDate,
                    onSave: { newDate in
                        store.updateItem(id: item.id) { updated in
                            updated.dueDate = newDate
                        }
                    },
                    onDone: { editingDueDateItem = nil }
                )
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let itemsToDelete = offsets.map { filteredItems[$0] }
        itemsToDelete.forEach { item in
            store.deleteItem(id: item.id)
        }
    }

    private func beginDueDateEdit(for item: Item) {
        editingDueDate = item.dueDate ?? Date()
        editingDueDateItem = item
    }

    private func isExpired(_ item: Item) -> Bool {
        guard item.type == .task, let dueDate = item.dueDate else {
            return false
        }
        let today = Date()
        return Calendar.current.compare(dueDate, to: today, toGranularity: .day) == .orderedAscending
    }
}

private struct DueDateEditSheet: View {
    let item: Item
    @Binding var dueDate: Date
    let onSave: (Date) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Due date", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
            }
            .navigationTitle("Update Due Date")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone()
                    }
                }
            }
        }
        .onChange(of: dueDate) { _, newValue in
            onSave(newValue)
        }
    }
}

struct InboxView_Previews: PreviewProvider {
    static var previews: some View {
        InboxView(store: ItemStore())
    }
}
