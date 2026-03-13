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
    private var hasCompletedInitialLoad = false
    private var hasMutatedBeforeInitialLoad = false

    init(fileURL: URL? = nil) {
        let start = Date()
        self.fileURL = fileURL ?? Self.defaultFileURL()
        AppPerformanceLogger.shared.mark("ItemStore init", since: start)
        Task { [weak self, fileURL = self.fileURL] in
            guard let self else { return }
            let (loadedItems, shouldSeed) = await Self.loadItems(from: fileURL)
            self.finishInitialLoad(loadedItems: loadedItems, shouldSeed: shouldSeed, startedAt: start)
        }
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
        markMutationBeforeInitialLoad()
        items.insert(item, at: 0)
        save()
    }

    func updateItem(id: UUID, update: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        markMutationBeforeInitialLoad()
        var item = items[index]
        update(&item)
        items[index] = item
        save()
    }

    func deleteItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        markMutationBeforeInitialLoad()
        let removedItem = items.remove(at: index)
        deletedHistory.append(DeletedItem(item: removedItem, index: index, deletedAt: Date()))
        if deletedHistory.count > 10 {
            deletedHistory.removeFirst(deletedHistory.count - 10)
        }
        save()
    }

    func toggleCompletion(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        markMutationBeforeInitialLoad()
        items[index].isCompleted.toggle()
        save()
    }

    func setCompletion(id: UUID, isCompleted: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        markMutationBeforeInitialLoad()
        items[index].isCompleted = isCompleted
        save()
    }

    func undoLastDelete() {
        guard let lastDeleted = deletedHistory.popLast() else {
            return
        }

        markMutationBeforeInitialLoad()
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

    private func finishInitialLoad(loadedItems: [Item], shouldSeed: Bool, startedAt: Date) {
        let resolvedItems = shouldSeed ? Self.seedItems() : loadedItems
        if hasMutatedBeforeInitialLoad {
            items = mergeLoadedItems(resolvedItems, into: items)
        } else {
            items = resolvedItems
        }
        hasCompletedInitialLoad = true
        if shouldSeed && !hasMutatedBeforeInitialLoad {
            save()
            AppPerformanceLogger.shared.mark("ItemStore load (seeded)", since: startedAt)
        } else {
            AppPerformanceLogger.shared.mark("ItemStore load", since: startedAt)
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

    private func markMutationBeforeInitialLoad() {
        if !hasCompletedInitialLoad {
            hasMutatedBeforeInitialLoad = true
        }
    }

    private func mergeLoadedItems(_ loadedItems: [Item], into currentItems: [Item]) -> [Item] {
        var merged: [UUID: Item] = Dictionary(uniqueKeysWithValues: loadedItems.map { ($0.id, $0) })
        for item in currentItems {
            merged[item.id] = item
        }
        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }

    private static func loadItems(from fileURL: URL) async -> ([Item], Bool) {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return ([], true)
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let items = try decoder.decode([Item].self, from: data)
                return (items, false)
            } catch {
                return ([], false)
            }
        }.value
    }

    private static func seedItems() -> [Item] {
        [
            Item(type: .note, title: "Welcome", details: "Add your first thought or task."),
            Item(type: .idea, title: "Sample idea", details: "Capture quick ideas here.")
        ]
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
