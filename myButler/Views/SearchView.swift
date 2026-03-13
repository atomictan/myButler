import SwiftUI

struct SearchView: View {
    // Shared store for accessing captured items.
    @ObservedObject var store: ItemStore
    // Local state for the active search text.
    @State private var query = ""

    // Filters items by title, details, or raw text.
    private var filteredItems: [Item] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return store.items
        }

        let loweredQuery = trimmedQuery.lowercased()
        return store.items.filter { item in
            item.title.lowercased().contains(loweredQuery)
                || item.details.lowercased().contains(loweredQuery)
                || item.rawText.lowercased().contains(loweredQuery)
                || (item.project?.lowercased().contains(loweredQuery) ?? false)
                || item.tags.contains { $0.lowercased().contains(loweredQuery) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredItems.isEmpty {
                    // Empty-state when no results match the query.
                    ContentUnavailableView("No results", systemImage: "magnifyingglass")
                } else {
                    List {
                        ForEach(filteredItems) { item in
                            NavigationLink {
                                ItemDetailView(item: item, store: store)
                            } label: {
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
                    .themedScrollableBackground()
                }
            }
            .navigationTitle("Search")
            .themedBackground()
        }
        // Search bar that binds to the local query state.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
    }

    private func deleteItems(at offsets: IndexSet) {
        let itemsToDelete = offsets.map { filteredItems[$0] }
        itemsToDelete.forEach { item in
            store.deleteItem(id: item.id)
        }
    }
}

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView(store: ItemStore())
    }
}
