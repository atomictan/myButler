import CryptoKit
import Foundation
import NaturalLanguage

struct EmbeddingMatch {
    let item: Item
    let score: Double
}

final class LocalEmbeddingIndex {
    private struct EmbeddingRecord: Codable {
        let id: UUID
        let textHash: String
        let vector: [Double]
    }

    private struct EmbeddingSnapshot: Codable {
        let modelVersion: String
        let records: [EmbeddingRecord]
    }

    private let fileURL: URL
    private let modelVersion: String
    private var records: [UUID: EmbeddingRecord] = [:]
    private let languageRecognizer = NLLanguageRecognizer()
    private static var hasLoggedInit = false

    init(fileURL: URL? = nil, modelVersion: String = "nl-embedding-v1") {
        let start = Date()
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.modelVersion = modelVersion
        load()
        if !Self.hasLoggedInit {
            Self.hasLoggedInit = true
            AppPerformanceLogger.shared.mark("LocalEmbeddingIndex init", since: start)
        }
    }

    func currentModelVersion() -> String {
        modelVersion
    }

    func search(query: String, items: [Item], limit: Int, minScore: Double) -> [EmbeddingMatch] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }
        updateIndex(for: items)
        guard let queryVector = embeddingVector(for: normalizedQuery) else { return [] }

        let candidates = items.filter { $0.type == .task || $0.type == .idea }
        var matches: [EmbeddingMatch] = []
        matches.reserveCapacity(candidates.count)
        for item in candidates {
            guard let record = records[item.id] else { continue }
            let score = cosineSimilarity(queryVector, record.vector)
            if score >= minScore {
                matches.append(EmbeddingMatch(item: item, score: score))
            }
        }

        let sorted = matches.sorted { $0.score > $1.score }
        return Array(sorted.prefix(limit))
    }

    func bestMatch(query: String, items: [Item]) -> EmbeddingMatch? {
        search(query: query, items: items, limit: 1, minScore: 0.0).first
    }

    private func updateIndex(for items: [Item]) {
        let candidates = items.filter { $0.type == .task || $0.type == .idea }
        var changed = false

        let activeIds = Set(candidates.map { $0.id })
        let staleIds = records.keys.filter { !activeIds.contains($0) }
        if !staleIds.isEmpty {
            for id in staleIds {
                records.removeValue(forKey: id)
            }
            changed = true
        }

        for item in candidates {
            let text = embeddingText(for: item)
            let textHash = sha256(text)
            if records[item.id]?.textHash == textHash {
                continue
            }
            guard let vector = embeddingVector(for: text) else { continue }
            records[item.id] = EmbeddingRecord(id: item.id, textHash: textHash, vector: vector)
            changed = true
        }

        if changed {
            save()
        }
    }

    private func embeddingText(for item: Item) -> String {
        let details = item.details.isEmpty ? "" : "\n\(item.details)"
        return "\(item.title)\(details)"
    }

    private func embeddingVector(for text: String) -> [Double]? {
        languageRecognizer.processString(text)
        let language = languageRecognizer.dominantLanguage ?? .english
        let embedding = NLEmbedding.sentenceEmbedding(for: language) ?? NLEmbedding.sentenceEmbedding(for: .english)
        return embedding?.vector(for: text)
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsSum = 0.0
        var rhsSum = 0.0
        for index in 0..<lhs.count {
            let leftValue = lhs[index]
            let rightValue = rhs[index]
            dot += leftValue * rightValue
            lhsSum += leftValue * leftValue
            rhsSum += rightValue * rightValue
        }
        let denominator = sqrt(lhsSum) * sqrt(rhsSum)
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    private func sha256(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(EmbeddingSnapshot.self, from: data) else { return }
        guard snapshot.modelVersion == modelVersion else { return }
        records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
    }

    private func save() {
        let snapshot = EmbeddingSnapshot(modelVersion: modelVersion, records: Array(records.values))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private static func defaultFileURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return documents[0].appendingPathComponent("item-embeddings.json")
    }
}
