import Foundation

struct StructuredDraft: Codable, Equatable {
    var type: ItemType
    var title: String
    var details: String
    var priority: ItemPriority
    var dueDate: Date?
    var tags: [String]

    init(
        type: ItemType = .note,
        title: String,
        details: String,
        priority: ItemPriority = .normal,
        dueDate: Date? = nil,
        tags: [String] = []
    ) {
        self.type = type
        self.title = title
        self.details = details
        self.priority = priority
        self.dueDate = dueDate
        self.tags = tags
    }
}
