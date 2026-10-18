import AppKit
import FileFormatterCore
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private var requested = false

    func notify(_ summary: RunSummary) {
        guard !NSApp.isActive else { return }
        Task {
            if !requested {
                requested = true
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = summary.failed == 0 ? "Formatting complete" : "Formatting finished with errors"
            content.body = "\(summary.converted) converted · \(summary.skipped) skipped · \(summary.failed) failed"
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: summary.id.uuidString,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
