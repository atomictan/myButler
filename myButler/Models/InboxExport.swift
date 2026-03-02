import Foundation

struct InboxExport: Codable {
    let version: Int
    let exportedAt: Date
    let items: [Item]
}

enum InboxImportMode: String, CaseIterable, Identifiable {
    case merge
    case replace
    case skipDuplicates

    var id: String { rawValue }

    var label: String {
        switch self {
        case .merge:
            return "Merge (keep latest)"
        case .replace:
            return "Replace inbox"
        case .skipDuplicates:
            return "Skip duplicates"
        }
    }
}

struct InboxImportResult {
    let totalCount: Int
}

enum InboxImportError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Inbox export version \(version) is not supported on this app version."
        case .invalidFormat:
            return "This file does not look like a MyButler inbox export."
        }
    }
}
