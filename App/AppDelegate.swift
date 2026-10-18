import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.addFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func convertFiles(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL], !urls.isEmpty else {
            error.pointee = "Select one or more files in Finder." as NSString
            return
        }
        AppModel.shared.addFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
    }
}
