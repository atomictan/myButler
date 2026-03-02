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

    private var sortedItems: [Item] {
        switch sortOption {
        case .created:
            return store.items
        case .priority:
            return store.items.sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority.rawValue > rhs.priority.rawValue
                }
                return lhs.createdAt > rhs.createdAt
            }
        case .dueDate:
            return store.items.sorted { lhs, rhs in
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
        sortedItems.filter { $0.type == filterOption.itemType }
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
                        }

                        ForEach(filteredItems) { item in
                            NavigationLink {
                                ItemDetailView(item: item, store: store)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                    if !item.details.isEmpty {
                                        Text(item.details)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(item.type.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 8) {
                                        Text(item.priority.label)
                                        if let dueDate = item.dueDate {
                                            Text("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
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
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: deleteItems)
                    }
                }
            }
            .navigationTitle("Inbox")
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
                AddItemView(store: store)
            }
            // Presents the voice capture flow.
            .sheet(isPresented: $isShowingVoiceCapture) {
                VoiceCaptureView(store: store)
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let itemsToDelete = offsets.map { filteredItems[$0] }
        itemsToDelete.forEach { item in
            store.deleteItem(id: item.id)
        }
    }
}

#Preview {
    InboxView(store: ItemStore())
}
