import Foundation

enum DueDateParser {
    private static let spokenHourNumbers: [(String, String)] = [
        ("twelve", "12"),
        ("eleven", "11"),
        ("ten", "10"),
        ("nine", "9"),
        ("eight", "8"),
        ("seven", "7"),
        ("six", "6"),
        ("five", "5"),
        ("four", "4"),
        ("three", "3"),
        ("two", "2"),
        ("one", "1")
    ]

    private static let spokenOrdinals: [(String, String)] = [
        ("thirty first", "31st"),
        ("thirtieth", "30th"),
        ("twenty ninth", "29th"),
        ("twenty eighth", "28th"),
        ("twenty seventh", "27th"),
        ("twenty sixth", "26th"),
        ("twenty fifth", "25th"),
        ("twenty fourth", "24th"),
        ("twenty third", "23rd"),
        ("twenty second", "22nd"),
        ("twenty first", "21st"),
        ("twentieth", "20th"),
        ("nineteenth", "19th"),
        ("eighteenth", "18th"),
        ("seventeenth", "17th"),
        ("sixteenth", "16th"),
        ("fifteenth", "15th"),
        ("fourteenth", "14th"),
        ("thirteenth", "13th"),
        ("twelfth", "12th"),
        ("eleventh", "11th"),
        ("tenth", "10th"),
        ("ninth", "9th"),
        ("eighth", "8th"),
        ("seventh", "7th"),
        ("sixth", "6th"),
        ("fifth", "5th"),
        ("fourth", "4th"),
        ("third", "3rd"),
        ("second", "2nd"),
        ("first", "1st")
    ]

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    private static let dateTimeSecondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = isoFormatter.date(from: value) {
            return date
        }
        if let date = dateTimeFormatter.date(from: value) {
            return date
        }
        if let date = dateTimeSecondsFormatter.date(from: value) {
            return date
        }
        return dateOnlyFormatter.date(from: value)
    }

    static func detect(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let normalizedText = normalizeDetectedText(text)
        let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        let matches = detector.matches(in: normalizedText, options: [], range: range)
        if let combined = combinedDate(from: matches, in: normalizedText) {
            return combined
        }
        return matches.first?.date
    }

    static func referenceTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func normalizeDetectedText(_ text: String) -> String {
        var normalized = " \(text.lowercased()) "
        for (spoken, numeric) in spokenOrdinals {
            normalized = normalized.replacingOccurrences(of: " \(spoken) ", with: " \(numeric) ")
        }
        for (spoken, numeric) in spokenHourNumbers {
            normalized = normalized.replacingOccurrences(of: " \(spoken) am ", with: " \(numeric) am ")
            normalized = normalized.replacingOccurrences(of: " \(spoken) pm ", with: " \(numeric) pm ")
            normalized = normalized.replacingOccurrences(of: " at \(spoken) ", with: " at \(numeric) ")
        }
        normalized = normalized.replacingOccurrences(of: " in the afternoon ", with: " pm ")
        normalized = normalized.replacingOccurrences(of: " in the morning ", with: " am ")
        normalized = normalized.replacingOccurrences(of: " in the evening ", with: " pm ")
        normalized = replacing(pattern: #"\b(\d)\s+(\d)\s*(st|nd|rd|th)\b"#, in: normalized, template: "$1$2$3")
        normalized = replacing(pattern: #"\b(\d{1,2})\s+(st|nd|rd|th)\b"#, in: normalized, template: "$1$2")
        normalized = replacing(pattern: #"\s+"#, in: normalized, template: " ")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func combinedDate(from matches: [NSTextCheckingResult], in text: String) -> Date? {
        guard matches.count >= 2 else { return nil }
        let calendar = Calendar.current

        let dateMatch = matches.first { match in
            guard let range = Range(match.range, in: text) else { return false }
            let fragment = String(text[range])
            return containsExplicitCalendarDate(fragment) && !containsExplicitClockOrMeridiem(fragment)
        }

        let timeMatch = matches.first { match in
            guard let range = Range(match.range, in: text) else { return false }
            let fragment = String(text[range])
            return containsExplicitClockOrMeridiem(fragment)
        }

        guard let dateOnly = dateMatch?.date,
              let timeOnly = timeMatch?.date else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: dateOnly)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: timeOnly)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second
        return calendar.date(from: components)
    }

    private static func containsExplicitCalendarDate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let monthNames = [
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"
        ]
        return monthNames.contains(where: { lower.contains($0) }) || lower.range(of: #"\b\d{1,2}(st|nd|rd|th)?\b"#, options: .regularExpression) != nil
    }

    private static func containsExplicitClockOrMeridiem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("am")
            || lower.contains("pm")
            || lower.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
