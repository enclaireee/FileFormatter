import Carbon.HIToolbox
import Foundation

/// System-wide shortcut via Carbon hot keys: no Accessibility permission needed.
@MainActor
final class HotKey {
    static let shared = HotKey()
    var onPress: () -> Void = {}
    /// True when macOS refused the last registration (for example, another app owns the combo).
    private(set) var failed = false

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Re-registers from Settings. Call at launch and after any shortcut setting changes.
    func apply() {
        unregister()
        guard AppSettings.bool(AppSettings.hotkeyEnabled) else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                // Application event target callbacks arrive on the main thread.
                MainActor.assumeIsolated { HotKey.shared.onPress() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let defaults = UserDefaults.standard
        // Hand-edited defaults must not crash launch or grab a bare key system-wide.
        guard let code = UInt32(exactly: defaults.integer(forKey: AppSettings.hotkeyKeyCode)),
              let mods = UInt32(exactly: defaults.integer(forKey: AppSettings.hotkeyModifiers)),
              mods & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            failed = true
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4646_4B59), id: 1) // "FFKY"
        failed = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) != noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        failed = false
    }
}
