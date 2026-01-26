import SwiftUI

struct ItemDetailView: View {
    // Item to display in the detail screen.
    let item: Item

    var body: some View {
        Form {
            Section("Title") {
                // Primary title for the item.
                Text(item.title)
                    .font(.headline)
            }

            Section("Details") {
                if item.details.isEmpty {
                    // Placeholder if no details were provided.
                    Text("No details yet")
                        .foregroundStyle(.secondary)
                } else {
                    // Full notes captured for the item.
                    Text(item.details)
                }
            }

            Section("Metadata") {
                // Category tag so users know the item type.
                LabeledContent("Type", value: item.type.rawValue.capitalized)
                // Timestamp for when the item was captured.
                LabeledContent("Captured", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle("Item")
    }
}

#Preview {
    ItemDetailView(item: Item(type: .note, title: "Sample", details: "Sample details"))
}
