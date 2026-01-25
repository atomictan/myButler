import Combine
import Foundation

// Central store that loads/saves items and feeds the UI.
@MainActor
final class ItemStore: ObservableObject {
    // Read-only outside this class to keep mutations controlled.
    @Published private(set) var items: [Item] = []

    // Location of the JSON file in the app's Documents folder.
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    // Adds a new item and persists it.
    func addItem(type: ItemType, title: String, details: String, rawText: String? = nil) {
        let item = Item(type: type, title: title, details: details, rawText: rawText)
        items.insert(item, at: 0)
        save()
    }

    // Loads existing items or seeds sample data on first run.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = [
                Item(type: .note, title: "Welcome", details: "Add your first thought or task."),
                Item(type: .idea, title: "Sample idea", details: "Capture quick ideas here.")
            ]
            save()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([Item].self, from: data)
        } catch {
            // If decoding fails, fall back to an empty list.
            items = []
        }
    }

    // Persists items to disk as JSON.
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Silently ignore write failures for now (can add error UI later).
            return
        }
    }

    // Default file location used by the app.
    private static func defaultFileURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return documents[0].appendingPathComponent("items.json")
    }
}
