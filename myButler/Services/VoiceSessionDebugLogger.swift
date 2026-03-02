import Foundation

final class VoiceSessionDebugLogger {
    private static let latestRunLogPathsKey = "voiceSessionLatestRunLogPaths"
    private let fileURL: URL
    private let queue = DispatchQueue(label: "VoiceSessionDebugLogger")

    var logURL: URL {
        fileURL
    }

    init?(sessionStart: Date) {
        guard let logsDirectory = Self.logsDirectoryURL() else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "voice-session-\(formatter.string(from: sessionStart)).log"
        fileURL = logsDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        log("Session started at \(sessionStart)")
    }

    static func logsDirectoryURL() -> URL? {
        let logsDirectory: URL
        if let baseURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            logsDirectory = baseURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("MyButlerLogs", isDirectory: true)
        } else {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return nil
            }
            logsDirectory = documents.appendingPathComponent("MyButlerLogs", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return logsDirectory
    }

    static func listLogFiles() -> [URL] {
        guard let directory = logsDirectoryURL() else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { ["log", "txt", "json", "jsonl"].contains($0.pathExtension) }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
    }

    static func clearAllLogs() {
        guard let directory = logsDirectoryURL() else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func exportLogsForFileSharing() -> String {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Documents directory not available."
        }

        guard let logsDirectory = logsDirectoryURL() else {
            return "Logs directory not available."
        }
        let logs = (try? FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil)) ?? []
        guard !logs.isEmpty else {
            return "No log files found to export."
        }

        var exportedCount = 0
        for log in logs {
            let destination = documents.appendingPathComponent(log.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: log, to: destination)
                exportedCount += 1
            } catch {
                continue
            }
        }

        return "Exported \(exportedCount) log file(s) to the app Documents folder for Finder sharing."
    }

    static func autoExportLogsForFileSharing() {
        _ = clearExportedLogsForFileSharing()
        _ = exportLogsForFileSharing()
    }

    static func exportLogsForFileSharing(urls: [URL]) -> [URL] {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        var exported: [URL] = []
        for log in urls {
            let destination = documents.appendingPathComponent(log.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: log, to: destination)
                exported.append(destination)
            } catch {
                continue
            }
        }
        return exported
    }

    static func exportedLogFiles() -> [URL] {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let filtered = urls.filter { url in
            let name = url.lastPathComponent
            let isLog = ["log", "txt", "json", "jsonl"].contains(url.pathExtension)
            let hasPrefix = name.hasPrefix("voice-session-")
                || name.hasPrefix("logs-debug-info-")
                || name.hasPrefix("voice-monitor-")
                || name.hasPrefix("voice-items-")
                || name.hasPrefix("voice-embedding-metrics-")
            return isLog && hasPrefix
        }
        return filtered.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
    }

    static func storeLatestRunLogFiles(_ urls: [URL]) {
        let paths = urls.map { $0.path }
        UserDefaults.standard.set(paths, forKey: latestRunLogPathsKey)
    }

    static func latestRunLogFiles() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: latestRunLogPathsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func debugInfoText() -> String {
        var lines: [String] = []
        lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")")
        let fileSharing = Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool ?? false
        let documentsInPlace = Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool ?? false
        lines.append("UIFileSharingEnabled: \(fileSharing)")
        lines.append("LSSupportsOpeningDocumentsInPlace: \(documentsInPlace)")

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        lines.append("Documents: \(documentsURL?.path ?? "unknown")")

        if let logsURL = logsDirectoryURL() {
            lines.append("Logs: \(logsURL.path)")
            let exists = FileManager.default.fileExists(atPath: logsURL.path)
            lines.append("Logs exist: \(exists)")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: logsURL.path)) ?? []
            let logFiles = files.filter { $0.hasSuffix(".log") || $0.hasSuffix(".txt") }
            lines.append("Log files: \(logFiles.joined(separator: ", "))")
        } else {
            lines.append("Logs: unavailable")
        }

        let iCloudAvailable = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
        lines.append("iCloud available: \(iCloudAvailable)")
        return lines.joined(separator: "\n")
    }

    static func writeDebugInfoFile() -> URL? {
        let content = debugInfoText()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "logs-debug-info-\(formatter.string(from: Date())).txt"

        guard let targetDirectory = logsDirectoryURL() else { return nil }
        let fileURL = targetDirectory.appendingPathComponent(filename)
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    static func writeLogFile(named filename: String, contents: String) -> URL? {
        guard let targetDirectory = logsDirectoryURL() else { return nil }
        let fileURL = targetDirectory.appendingPathComponent(filename)
        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    static func clearExportedLogsForFileSharing() -> String {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Documents directory not available."
        }

        let urls = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        let logFiles = urls.filter { $0.lastPathComponent.hasPrefix("voice-session-") && $0.pathExtension == "log" }
        guard !logFiles.isEmpty else { return "No exported log files found." }

        var removedCount = 0
        for url in logFiles {
            do {
                try FileManager.default.removeItem(at: url)
                removedCount += 1
            } catch {
                continue
            }
        }

        return "Removed \(removedCount) exported log file(s) from the app Documents folder."
    }

    func log(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            do {
                let handle = try FileHandle(forWritingTo: self.fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                return
            }
        }
    }

    func logTranscript(_ transcript: String) {
        log("TRANSCRIPT_START")
        log(transcript)
        log("TRANSCRIPT_END")
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    static func writeICloudTestFile() -> String {
        guard let baseURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return "iCloud Drive is not available on this device."
        }
        let logsDirectory = baseURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MyButlerLogs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let fileURL = logsDirectory.appendingPathComponent("icloud-test-\(formatter.string(from: Date())).txt")
            let content = "MyButler iCloud sync test at \(Date())\n"
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Wrote test file to iCloud: \(fileURL.lastPathComponent)"
        } catch {
            return "Failed to write iCloud test file: \(error.localizedDescription)"
        }
    }
}
