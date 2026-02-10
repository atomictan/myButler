import SwiftUI

struct UndoHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ItemStore

    var body: some View {
        NavigationStack {
            Group {
                if store.deletedHistory.isEmpty {
                    ContentUnavailableView("No deleted items", systemImage: "trash")
                } else {
                    List {
                        ForEach(store.deletedHistory.reversed()) { deletedItem in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(deletedItem.item.title.isEmpty ? "Untitled" : deletedItem.item.title)
                                    .font(.headline)
                                if !deletedItem.item.details.isEmpty {
                                    Text(deletedItem.item.details)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                metadataRow(for: deletedItem)
                                Button("Restore") {
                                    store.restoreDeletedItem(deletedItem)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Deleted Items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") {
                        store.clearDeletedHistory()
                    }
                    .disabled(store.deletedHistory.isEmpty)
                }
            }
        }
    }

    private func metadataRow(for deletedItem: DeletedItem) -> some View {
        HStack(spacing: 8) {
            Text(deletedItem.deletedAt.formatted(date: .abbreviated, time: .shortened))
            if let project = deletedItem.item.project, !project.isEmpty {
                Text(project)
            }
            if !deletedItem.item.tags.isEmpty {
                Text(deletedItem.item.tags.joined(separator: ", "))
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    UndoHistoryView(store: ItemStore())
}
