import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NotificationService.shared.register()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.addFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func convertFiles(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let urls = fileURLs(pasteboard, error: error) else { return }
        AppModel.shared.addFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finder Services → one-shot conversion next to the originals, no window.
    @objc func quickAction(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let urls = fileURLs(pasteboard, error: error) else { return }
        guard let action = QuickAction(id: userData) else {
            error.pointee = "Unknown FileFormatter action." as NSString
            return
        }
        Task {
            if let summary = await AppModel.shared.quickRun(urls: urls, action: action) {
                NotificationService.shared.notify(summary, force: true)
            }
        }
    }

    private func fileURLs(
        _ pasteboard: NSPasteboard,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            error.pointee = "Select one or more files in Finder." as NSString
            return nil
        }
        return urls
    }
}
