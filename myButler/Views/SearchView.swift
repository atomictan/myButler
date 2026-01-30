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
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredItems.isEmpty {
                    // Empty-state when no results match the query.
                    ContentUnavailableView("No results", systemImage: "magnifyingglass")
                } else {
                    List(filteredItems) { item in
                        // Navigate to the same item detail view.
                        NavigationLink {
                            ItemDetailView(item: item, store: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                // Title for the search result row.
                                Text(item.title)
                                    .font(.headline)
                                if !item.details.isEmpty {
                                    // Short preview for the result row.
                                    Text(item.details)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                // Item type badge for quick scanning.
                                Text(item.type.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Text(item.priority.label)
                                    if let dueDate = item.dueDate {
                                        Text("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
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
                }
            }
            .navigationTitle("Search")
        }
        // Search bar that binds to the local query state.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
    }
}

#Preview {
    SearchView(store: ItemStore())
}
