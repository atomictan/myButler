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

struct InboxView: View {
    @ObservedObject var store: ItemStore
    @State private var isShowingAdd = false
    @State private var isShowingVoiceCapture = false
    @State private var sortOption: InboxSortOption = .created

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

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    // Empty-state placeholder when there are no items.
                    ContentUnavailableView("No items yet", systemImage: "tray")
                } else {
                    List(sortedItems) { item in
                        // Each row links to the item detail screen.
                        NavigationLink {
                            ItemDetailView(item: item, store: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                // Main title shown in the list.
                                Text(item.title)
                                    .font(.headline)
                                if !item.details.isEmpty {
                                    // Secondary description if provided.
                                    Text(item.details)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                // Type label for quick scanning.
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
}

#Preview {
    InboxView(store: ItemStore())
}
