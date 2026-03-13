import SwiftUI

struct WeeklyDigestView: View {
    @ObservedObject var store: ItemStore
    @State private var digestDate = Date()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weekly Digest")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Past 7 days")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)

            Section("Summary") {
                LabeledContent("Generated", value: digestDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Items this week", value: "\(weeklyItems.count)")
                LabeledContent("Waiting on", value: "\(waitingOnItems.count)")
                LabeledContent("Stale", value: "\(staleItems.count)")
            }

            Section("Top 3") {
                if topItems.isEmpty {
                    Text("No items captured this week.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topItems) { item in
                        NavigationLink {
                            ItemDetailView(item: item, store: store)
                        } label: {
                            itemRow(for: item)
                        }
                    }
                }
            }

            Section("Waiting On") {
                if waitingOnItems.isEmpty {
                    Text("Nothing waiting on someone else.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(waitingOnItems) { item in
                        NavigationLink {
                            ItemDetailView(item: item, store: store)
                        } label: {
                            itemRow(for: item)
                        }
                    }
                }
            }

            Section("Stale") {
                if staleItems.isEmpty {
                    Text("No stale items right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(staleItems) { item in
                        NavigationLink {
                            ItemDetailView(item: item, store: store)
                        } label: {
                            itemRow(for: item)
                        }
                    }
                }
            }
        }
        .themedScrollableBackground()
        .navigationTitle("Weekly Digest")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Generate") {
                    digestDate = Date()
                }
            }
        }
    }

    private var startOfWeek: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: digestDate) ?? digestDate
    }

    private var weeklyItems: [Item] {
        store.items.filter { item in
            item.createdAt >= startOfWeek && item.createdAt <= digestDate
        }
    }

    private var topItems: [Item] {
        weeklyItems
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority.rawValue > rhs.priority.rawValue
                }
                let lhsDate = lhs.dueDate ?? Date.distantFuture
                let rhsDate = rhs.dueDate ?? Date.distantFuture
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(3)
            .map { $0 }
    }

    private var waitingOnItems: [Item] {
        let keywords = ["waiting", "await", "blocked"]
        return store.items.filter { item in
            let title = item.title.lowercased()
            let details = item.details.lowercased()
            let hasKeyword = keywords.contains { keyword in
                title.contains(keyword) || details.contains(keyword)
            }
            let hasTag = item.tags.contains { tag in
                keywords.contains(tag.lowercased())
            }
            return hasKeyword || hasTag
        }
    }

    private var staleItems: [Item] {
        let staleDate = Calendar.current.date(byAdding: .day, value: -14, to: digestDate) ?? digestDate
        return store.items
            .filter { $0.createdAt < staleDate }
            .sorted { $0.createdAt < $1.createdAt }
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

struct WeeklyDigestView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            WeeklyDigestView(store: ItemStore())
        }
    }
}
