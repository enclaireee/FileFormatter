import AppKit
import FileFormatterCore
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private static let category = "run"
    private static let reveal = "reveal"
    private static let undo = "undo"

    private var requested = false
    private var notified: Set<UUID> = []
    // ponytail: summaries live only for this launch; notification buttons after a relaunch just open the app.
    private var summaries: [UUID: RunSummary] = [:]

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.reveal, title: "Show in Finder"),
                    UNNotificationAction(identifier: Self.undo, title: "Undo", options: .destructive)
                ],
                intentIdentifiers: []
            )
        ])
    }

    /// `force` posts even while the app is frontmost (Finder services activate it).
    func notify(_ summary: RunSummary, force: Bool = false) {
        guard force || !NSApp.isActive, notified.insert(summary.id).inserted else { return }
        summaries[summary.id] = summary
        Task {
            if !requested {
                requested = true
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = summary.failed == 0 ? "\(summary.target) done" : "\(summary.target) finished with errors"
            content.body = "\(summary.converted) converted · \(summary.skipped) skipped · \(summary.failed) failed"
            content.categoryIdentifier = Self.category
            content.userInfo = ["summary": summary.id.uuidString]
            let request = UNNotificationRequest(identifier: summary.id.uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo["summary"] as? String).flatMap(UUID.init)
        await MainActor.run { handle(action: action, id: id) }
    }

    private func handle(action: String, id: UUID?) {
        guard let id, let summary = summaries[id] else { return }
        switch action {
        case Self.undo:
            Task { _ = await AppModel.shared.undo(summary) }
        default:
            let outputs = summary.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        }
    }
}
