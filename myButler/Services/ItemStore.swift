import Combine
import Foundation

// Central store that loads/saves items and feeds the UI.
@MainActor
final class ItemStore: ObservableObject {
    // Read-only outside this class to keep mutations controlled.
    @Published private(set) var items: [Item] = []
    @Published private(set) var deletedHistory: [DeletedItem] = []

    var latestDeleted: DeletedItem? {
        deletedHistory.last
    }

    // Location of the JSON file in the app's Documents folder.
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    // Adds a new item and persists it.
    func addItem(
        type: ItemType,
        title: String,
        details: String,
        rawText: String? = nil,
        priority: ItemPriority = .normal,
        dueDate: Date? = nil,
        tags: [String] = [],
        project: String? = nil
    ) {
        let item = Item(
            type: type,
            title: title,
            details: details,
            rawText: rawText,
            priority: priority,
            dueDate: dueDate,
            tags: tags,
            project: project
        )
        items.insert(item, at: 0)
        save()
    }

    func updateItem(id: UUID, update: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        var item = items[index]
        update(&item)
        items[index] = item
        save()
    }

    func deleteItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedItem = items.remove(at: index)
        deletedHistory.append(DeletedItem(item: removedItem, index: index, deletedAt: Date()))
        if deletedHistory.count > 10 {
            deletedHistory.removeFirst(deletedHistory.count - 10)
        }
        save()
    }

    func undoLastDelete() {
        guard let lastDeleted = deletedHistory.popLast() else {
            return
        }

        let insertionIndex = min(lastDeleted.index, items.count)
        items.insert(lastDeleted.item, at: insertionIndex)
        save()
    }

    func restoreDeletedItem(_ deletedItem: DeletedItem) {
        guard let index = deletedHistory.firstIndex(where: { $0.id == deletedItem.id }) else {
            return
        }
        deletedHistory.remove(at: index)

        let insertionIndex = min(deletedItem.index, items.count)
        items.insert(deletedItem.item, at: insertionIndex)
        save()
    }

    func clearDeletedHistory() {
        deletedHistory.removeAll()
    }

    func exportInbox() throws -> URL {
        let export = InboxExport(version: 1, exportedAt: Date(), items: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)

        let exportURL = try Self.exportFileURL()
        try data.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    func importInbox(from url: URL, mode: InboxImportMode) throws -> InboxImportResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let importedItems: [Item]
        if let export = try? decoder.decode(InboxExport.self, from: data) {
            if export.version > 1 {
                throw InboxImportError.unsupportedVersion(export.version)
            }
            importedItems = export.items
        } else if let legacyItems = try? decoder.decode([Item].self, from: data) {
            importedItems = legacyItems
        } else {
            throw InboxImportError.invalidFormat
        }

        switch mode {
        case .replace:
            items = importedItems.sorted { $0.createdAt > $1.createdAt }
            deletedHistory.removeAll()
        case .merge:
            var merged: [UUID: Item] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            for item in importedItems {
                if let existing = merged[item.id] {
                    if item.createdAt > existing.createdAt {
                        merged[item.id] = item
                    }
                } else {
                    merged[item.id] = item
                }
            }
            items = merged.values.sorted { $0.createdAt > $1.createdAt }
        case .skipDuplicates:
            let existingIds = Set(items.map { $0.id })
            let newItems = importedItems.filter { !existingIds.contains($0.id) }
            items.append(contentsOf: newItems)
            items.sort { $0.createdAt > $1.createdAt }
        }

        save()
        return InboxImportResult(totalCount: items.count)
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

    private static func exportFileURL() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let exportDirectory = documents[0].appendingPathComponent("MyButlerExport", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "inbox-\(formatter.string(from: Date())).json"
        return exportDirectory.appendingPathComponent(filename)
    }
}

struct DeletedItem: Identifiable {
    let item: Item
    let index: Int
    let deletedAt: Date

    var id: UUID {
        item.id
    }
}
