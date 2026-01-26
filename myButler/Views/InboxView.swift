import SwiftUI

struct InboxView: View {
    @ObservedObject var store: ItemStore
    @State private var isShowingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    // Empty-state placeholder when there are no items.
                    ContentUnavailableView("No items yet", systemImage: "tray")
                } else {
                    List(store.items) { item in
                        // Each row links to the item detail screen.
                        NavigationLink {
                            ItemDetailView(item: item)
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
            }
            // Presents the add form.
            .sheet(isPresented: $isShowingAdd) {
                AddItemView(store: store)
            }
        }
    }
}

#Preview {
    InboxView(store: ItemStore())
}
