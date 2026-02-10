import SwiftUI

struct TodayView: View {
    @ObservedObject var store: ItemStore

    private var startOfDay: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var endOfDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }

    private var overdueItems: [Item] {
        store.items
            .filter { item in
                guard let dueDate = item.dueDate else { return false }
                return dueDate < startOfDay
            }
            .sorted(by: sortByDueDateThenCreated)
    }

    private var dueTodayItems: [Item] {
        store.items
            .filter { item in
                guard let dueDate = item.dueDate else { return false }
                return dueDate >= startOfDay && dueDate < endOfDay
            }
            .sorted(by: sortByDueDateThenCreated)
    }

    private var highPriorityItems: [Item] {
        store.items
            .filter { item in
                guard item.priority == .high else { return false }
                guard let dueDate = item.dueDate else { return true }
                return dueDate >= endOfDay
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var hasItems: Bool {
        !overdueItems.isEmpty || !dueTodayItems.isEmpty || !highPriorityItems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasItems {
                    List {
                        if !overdueItems.isEmpty {
                            Section("Overdue") {
                                ForEach(overdueItems) { item in
                                    NavigationLink {
                                        ItemDetailView(item: item, store: store)
                                    } label: {
                                        itemRow(for: item)
                                    }
                                }
                                .onDelete { offsets in
                                    deleteItems(from: overdueItems, at: offsets)
                                }
                            }
                        }
                        if !dueTodayItems.isEmpty {
                            Section("Due Today") {
                                ForEach(dueTodayItems) { item in
                                    NavigationLink {
                                        ItemDetailView(item: item, store: store)
                                    } label: {
                                        itemRow(for: item)
                                    }
                                }
                                .onDelete { offsets in
                                    deleteItems(from: dueTodayItems, at: offsets)
                                }
                            }
                        }
                        if !highPriorityItems.isEmpty {
                            Section("High Priority") {
                                ForEach(highPriorityItems) { item in
                                    NavigationLink {
                                        ItemDetailView(item: item, store: store)
                                    } label: {
                                        itemRow(for: item)
                                    }
                                }
                                .onDelete { offsets in
                                    deleteItems(from: highPriorityItems, at: offsets)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Nothing due today", systemImage: "sun.max")
                }
            }
            .navigationTitle("Today")
        }
    }

    private func sortByDueDateThenCreated(_ lhs: Item, _ rhs: Item) -> Bool {
        let lhsDate = lhs.dueDate ?? Date.distantFuture
        let rhsDate = rhs.dueDate ?? Date.distantFuture
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.createdAt > rhs.createdAt
    }

    private func itemRow(for item: Item) -> some View {
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

    private func deleteItems(from items: [Item], at offsets: IndexSet) {
        let itemsToDelete = offsets.map { items[$0] }
        itemsToDelete.forEach { item in
            store.deleteItem(id: item.id)
        }
    }
}

#Preview {
    TodayView(store: ItemStore())
}
