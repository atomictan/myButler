import Foundation
import UserNotifications

enum WeeklyDigestFrequency: String, CaseIterable, Identifiable {
    case weekly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly:
            return "Weekly"
        }
    }
}

struct WeeklyDigestSchedule {
    let frequency: WeeklyDigestFrequency
    let weekday: Int
    let monthDay: Int
    let hour: Int
    let minute: Int
}

enum WeeklyDigestReminder {
    static let identifier = "weekly_digest_reminder"

    static func updateSchedule(isEnabled: Bool, schedule: WeeklyDigestSchedule) async {
        if isEnabled {
            let granted = await requestAuthorization()
            guard granted else { return }
            try? await scheduleReminder(schedule: schedule)
        } else {
            cancelWeeklyReminder()
        }
    }

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    static func scheduleReminder(schedule: WeeklyDigestSchedule) async throws {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Weekly Digest"
        content.body = "Ready for your weekly digest? Open the app to review. You can disable this reminder in Settings."
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = schedule.hour
        dateComponents.minute = schedule.minute
        dateComponents.weekday = schedule.weekday

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func cancelWeeklyReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
