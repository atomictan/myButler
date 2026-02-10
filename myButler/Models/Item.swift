import Foundation

// High-level category for an item so we can filter later.
enum ItemType: String, Codable, CaseIterable, Identifiable {
    case task
    case idea
    case note

    // Required for SwiftUI pickers and lists.
    var id: String { rawValue }
}

enum ItemPriority: Int, Codable, CaseIterable, Identifiable {
    case low = 0
    case normal = 1
    case high = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low:
            return "Low"
        case .normal:
            return "Normal"
        case .high:
            return "High"
        }
    }
}

// Core data model stored in JSON for now.
struct Item: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var type: ItemType
    var title: String
    var details: String
    var rawText: String
    var priority: ItemPriority
    var dueDate: Date?
    var tags: [String]
    var project: String?

    // Convenience initializer used by the Add screen.
    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        type: ItemType = .note,
        title: String,
        details: String,
        rawText: String? = nil,
        priority: ItemPriority = .normal,
        dueDate: Date? = nil,
        tags: [String] = [],
        project: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.title = title
        self.details = details
        // Raw text preserves the original capture for later AI parsing.
        self.rawText = rawText ?? details
        self.priority = priority
        self.dueDate = dueDate
        self.tags = tags
        self.project = project
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case type
        case title
        case details
        case rawText
        case priority
        case dueDate
        case tags
        case project
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        type = try container.decode(ItemType.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        details = try container.decode(String.self, forKey: .details)
        rawText = try container.decode(String.self, forKey: .rawText)
        priority = try container.decodeIfPresent(ItemPriority.self, forKey: .priority) ?? .normal
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        project = try container.decodeIfPresent(String.self, forKey: .project)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(details, forKey: .details)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(project, forKey: .project)
    }
}
