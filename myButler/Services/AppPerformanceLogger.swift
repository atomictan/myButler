import Foundation

final class AppPerformanceLogger: @unchecked Sendable {
    nonisolated static let shared = AppPerformanceLogger()

    private let queue = DispatchQueue(label: "AppPerformanceLogger")
    private let startedAt = Date()
    private let fileURL: URL?

    private init() {
        if let directory = VoiceSessionDebugLogger.logsDirectoryURL() {
            fileURL = directory.appendingPathComponent("app-performance.log")
            FileManager.default.createFile(atPath: fileURL?.path ?? "", contents: nil)
        } else {
            fileURL = nil
        }
    }

    nonisolated func log(_ message: String) {
        queue.async {
            self.appendLine(self.makeLine(message: message))
        }
    }

    nonisolated func snapshotForSharing(logging message: String) -> URL? {
        queue.sync {
            appendLine(makeLine(message: message))
            guard let fileURL else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let snapshotURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("app-performance-share-\(formatter.string(from: Date())).log")
            try? FileManager.default.removeItem(at: snapshotURL)
            do {
                try FileManager.default.copyItem(at: fileURL, to: snapshotURL)
                return snapshotURL
            } catch {
                return nil
            }
        }
    }

    nonisolated func mark(_ name: String, since start: Date) {
        let duration = Date().timeIntervalSince(start)
        log("\(name) completed in \(String(format: "%.3f", duration))s")
    }

    nonisolated private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    nonisolated private func makeLine(message: String) -> String {
        let elapsed = Date().timeIntervalSince(startedAt)
        return "[\(timestamp()) +\(String(format: "%.3f", elapsed))s] \(message)\n"
    }

    nonisolated private func appendLine(_ line: String) {
        guard let fileURL,
              let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            return
        }
    }
}
