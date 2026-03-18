import SwiftUI

struct ProjectsView: View {
    @ObservedObject var store: ItemStore

    private var groupedProjects: [(name: String, items: [Item])] {
        let grouped = Dictionary(grouping: store.items) { item in
            let trimmed = item.project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "No Project" : trimmed
        }

        return grouped
            .map { name, items in
                (name: name, items: items.sorted { $0.createdAt > $1.createdAt })
            }
            .sorted { lhs, rhs in
                if lhs.name == "No Project" {
                    return false
                }
                if rhs.name == "No Project" {
                    return true
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groupedProjects.isEmpty {
                    ContentUnavailableView("No projects yet", systemImage: "folder")
                } else {
                    List {
                        ForEach(groupedProjects, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.items) { item in
                                    NavigationLink {
                                        ItemDetailView(item: item, store: store)
                                    } label: {
                                        itemRow(for: item)
                                    }
                                }
                                .onDelete { offsets in
                                    deleteItems(from: group.items, at: offsets)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Projects")
        }
    }

    private func itemRow(for item: Item) -> some View {
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

struct ProjectsView_Previews: PreviewProvider {
    static var previews: some View {
        ProjectsView(store: ItemStore())
    }
}
