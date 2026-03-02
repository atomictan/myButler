import Foundation

struct VoiceSessionDiff: Codable {
    let creates: [VoiceSessionDiffCreate]
    let updates: [VoiceSessionDiffUpdate]
    let merges: [VoiceSessionDiffMerge]
    let deletes: [VoiceSessionDiffDelete]

    private enum CodingKeys: String, CodingKey {
        case creates
        case updates
        case merges
        case deletes
    }

    init(
        creates: [VoiceSessionDiffCreate] = [],
        updates: [VoiceSessionDiffUpdate] = [],
        merges: [VoiceSessionDiffMerge] = [],
        deletes: [VoiceSessionDiffDelete] = []
    ) {
        self.creates = creates
        self.updates = updates
        self.merges = merges
        self.deletes = deletes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        creates = try container.decodeIfPresent([VoiceSessionDiffCreate].self, forKey: .creates) ?? []
        updates = try container.decodeIfPresent([VoiceSessionDiffUpdate].self, forKey: .updates) ?? []
        merges = try container.decodeIfPresent([VoiceSessionDiffMerge].self, forKey: .merges) ?? []
        deletes = try container.decodeIfPresent([VoiceSessionDiffDelete].self, forKey: .deletes) ?? []
    }

    var isEmpty: Bool {
        creates.isEmpty && updates.isEmpty && merges.isEmpty && deletes.isEmpty
    }
}

struct VoiceSessionDiffCreate: Codable, Identifiable {
    let tempId: String
    let type: ItemType
    let title: String
    let details: String
    let dueDate: Date?
    let priority: ItemPriority
    let project: String?
    let tags: [String]

    var id: String { tempId }

    private enum CodingKeys: String, CodingKey {
        case tempId
        case type
        case title
        case details
        case dueDate
        case priority
        case project
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tempId = try container.decode(String.self, forKey: .tempId)
        type = ItemType(rawValue: try container.decode(String.self, forKey: .type)) ?? .note
        title = try container.decode(String.self, forKey: .title)
        details = try container.decode(String.self, forKey: .details)
        dueDate = VoiceSessionDiffDecode.date(from: try container.decodeIfPresent(String.self, forKey: .dueDate))
        priority = VoiceSessionDiffDecode.priority(from: try container.decodeIfPresent(String.self, forKey: .priority)) ?? .normal
        project = try container.decodeIfPresent(String.self, forKey: .project)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

struct VoiceSessionDiffUpdate: Codable, Identifiable {
    let id: String
    let changes: VoiceSessionDiffChanges
}

struct VoiceSessionDiffMerge: Codable, Identifiable {
    let sourceTempId: String
    let targetId: String
    let mergeSummary: String?

    var id: String { "\(sourceTempId)->\(targetId)" }
}

struct VoiceSessionDiffDelete: Codable, Identifiable {
    let id: String
    let reason: String?
}

struct VoiceSessionDiffChanges: Codable {
    let title: String?
    let details: String?
    let dueDate: Date?
    let priority: ItemPriority?
    let project: String?
    let tags: [String]?

    private enum CodingKeys: String, CodingKey {
        case title
        case details
        case dueDate
        case priority
        case project
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        dueDate = VoiceSessionDiffDecode.date(from: try container.decodeIfPresent(String.self, forKey: .dueDate))
        priority = VoiceSessionDiffDecode.priority(from: try container.decodeIfPresent(String.self, forKey: .priority))
        project = try container.decodeIfPresent(String.self, forKey: .project)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
    }
}

struct VoiceSessionDiffSelection: Codable {
    var createTempIds: Set<String>
    var updateIds: Set<String>
    var mergeSourceIds: Set<String>
    var deleteIds: Set<String>
}

private enum VoiceSessionDiffDecode {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return dateFormatter.date(from: value)
    }

    static func priority(from value: String?) -> ItemPriority? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "low":
            return .low
        case "high":
            return .high
        default:
            return .normal
        }
    }
}
