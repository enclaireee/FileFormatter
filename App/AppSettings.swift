import Foundation
import ServiceManagement

/// UserDefaults keys and defaults for the Settings window. Views bind with `@AppStorage(AppSettings.x)`.
enum AppSettings {
    static let useFolder = "output.useFolder"
    static let folderBookmark = "output.folderBookmark"
    static let keepMetadata = "metadata.keep"
    static let convertSuffix = "suffix.convert"
    static let compressSuffix = "suffix.compress"
    static let backgroundSuffix = "suffix.nobg"
    static let hdBackground = "background.hd"
    static let revealWhenDone = "output.revealWhenDone"
    static let shelfEnabled = "shelf.enabled"
    static let hotkeyEnabled = "hotkey.enabled"
    static let hotkeyKeyCode = "hotkey.keyCode"
    static let hotkeyModifiers = "hotkey.modifiers"
    static let hotkeyLabel = "hotkey.label"

    static func register() {
        UserDefaults.standard.register(defaults: [
            useFolder: false,
            keepMetadata: true,
            convertSuffix: "",
            compressSuffix: "-small",
            backgroundSuffix: "-nobg",
            hdBackground: true,
            revealWhenDone: true,
            shelfEnabled: true,
            // ⌥⌘F: Carbon key code 3, optionKey | cmdKey.
            hotkeyEnabled: true,
            hotkeyKeyCode: 3,
            hotkeyModifiers: 2048 | 256,
            hotkeyLabel: "⌥⌘F"
        ])
    }

    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    /// A file name ending from Settings, without characters that would change the folder.
    static func suffix(_ key: String) -> String {
        string(key).filter { $0 != "/" && $0 != ":" }
    }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    /// The bundled BiRefNet-lite (D-026); nil when missing from this build.
    static let bundledBackgroundModel = Bundle.main.url(forResource: "BiRefNetLite", withExtension: "mlmodelc", subdirectory: "Models")
    /// The model background removal should use; nil means Apple Vision.
    static var backgroundModel: URL? { bool(hdBackground) ? bundledBackgroundModel : nil }

    // MARK: Output folder

    /// Saves a security-scoped bookmark so the sandbox keeps write access after relaunch.
    static func setOutputFolder(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: folderBookmark)
    }

    /// Picks a new folder: drops access to the old one so the next lookup opens the new bookmark.
    @MainActor static func replaceOutputFolder(with url: URL) throws {
        try setOutputFolder(url)
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    /// Held open for the app's lifetime so the result UI (sizes, Copy, drag out, Undo) can read outputs after a run.
    @MainActor private static var scopedFolder: URL?

    /// The chosen folder, or nil for "next to the original". Check `useFolder` to tell nil apart from "unavailable".
    @MainActor static func outputFolder() -> URL? {
        guard bool(useFolder) else { return nil }
        return bookmarkedFolder()
    }

    /// The bookmarked folder with sandbox access open; nil if it was deleted or moved to the Trash.
    @MainActor static func bookmarkedFolder() -> URL? {
        if scopedFolder == nil, let data = UserDefaults.standard.data(forKey: folderBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                scopedFolder = url
                if stale { try? setOutputFolder(url) }
            }
        }
        guard let url = scopedFolder, FileManager.default.fileExists(atPath: url.path) else { return nil }
        var relation = FileManager.URLRelationship.other
        try? FileManager.default.getRelationship(&relation, of: .trashDirectory, in: .userDomainMask, toItemAt: url)
        return relation == .contains ? nil : url
    }

    // MARK: Login item

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpensAtLogin(_ on: Bool) throws {
        on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
    }
}
