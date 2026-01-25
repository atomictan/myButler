import Foundation

// High-level category for an item so we can filter later.
enum ItemType: String, Codable, CaseIterable, Identifiable {
    case task
    case idea
    case note

    // Required for SwiftUI pickers and lists.
    var id: String { rawValue }
}

// Core data model stored in JSON for now.
struct Item: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var type: ItemType
    var title: String
    var details: String
    var rawText: String

    // Convenience initializer used by the Add screen.
    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        type: ItemType = .note,
        title: String,
        details: String,
        rawText: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.title = title
        self.details = details
        // Raw text preserves the original capture for later AI parsing.
        self.rawText = rawText ?? details
    }
}
