import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.useFolder) private var useFolder = false
    @AppStorage(AppSettings.folderBookmark) private var bookmark = Data()
    @AppStorage(AppSettings.keepMetadata) private var keepMetadata = true
    @AppStorage(AppSettings.convertSuffix) private var convertSuffix = ""
    @AppStorage(AppSettings.compressSuffix) private var compressSuffix = "-small"
    @AppStorage(AppSettings.backgroundSuffix) private var backgroundSuffix = "-nobg"
    @AppStorage(AppSettings.hdBackground) private var hdBackground = true
    @AppStorage(AppSettings.shelfEnabled) private var shelfEnabled = true
    @AppStorage("compress.strength") private var strength = CompressSettings.Strength.balanced
    @AppStorage("compress.targetMB") private var targetMB = 10.0

    @AppStorage(AppSettings.hotkeyEnabled) private var hotkeyEnabled = true
    @AppStorage(AppSettings.hotkeyLabel) private var hotkeyLabel = "⌥⌘F"
    @State private var recorder: Any?
    @State private var hotkeyFailed = false
    @State private var opensAtLogin = AppSettings.opensAtLogin
    @State private var loginError: String?

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    /// Re-read whenever the bookmark changes.
    private var folder: URL? { _ = bookmark; return AppSettings.bookmarkedFolder() }

    var body: some View {
        Form {
            Section("Output") {
                Picker("Save to", selection: $useFolder) {
                    Text("Next to the original").tag(false)
                    Text("A folder").tag(true)
                }
                .onChange(of: useFolder) { _, on in
                    if on, folder == nil { chooseFolder() }
                }
                if useFolder {
                    HStack {
                        if let folder {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                                .resizable().frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                .help(folder.path)
                        } else {
                            Label("Folder unavailable, choose again", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if let folder {
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                        Button("Choose…", action: chooseFolder)
                            .disabled(AppModel.shared.isBusy)
                            .help(AppModel.shared.isBusy ? "Wait for the current conversion to finish" : "")
                    }
                }
                Toggle("Keep metadata (camera, location, dates)", isOn: $keepMetadata)
                Text("Compress always strips metadata to save space. The main window has its own switch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                suffixField("Converted", text: $convertSuffix, example: "photo.png → photo\(convertSuffix).jpg")
                suffixField("Compressed", text: $compressSuffix, example: "photo\(compressSuffix).jpg")
                suffixField("Background removed", text: $backgroundSuffix, example: "photo\(backgroundSuffix).png")
            } header: {
                Text("File name endings")
            } footer: {
                Text("If a file with that name exists, a number is added instead of replacing it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Background removal") {
                Toggle("HD edges (slower)", isOn: $hdBackground)
                    .disabled(AppSettings.bundledBackgroundModel == nil)
                Text(AppSettings.bundledBackgroundModel == nil
                     ? "The HD model isn't in this build, so Apple Vision is used."
                     : "Sharper hair and edges with a bundled model, about half a second per image. Off uses Apple Vision, which is instant.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Compress default") {
                Picker("Strength", selection: $strength) {
                    ForEach(CompressSettings.Strength.allCases) { Text($0.title).tag($0) }
                }
                if strength == .target {
                    LabeledContent("Target size") {
                        HStack(spacing: 4) {
                            TextField("MB", value: $targetMB, format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Text("MB per file").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("The popover's Compress panel starts here and remembers your last choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show drop pad while dragging files", isOn: $shelfEnabled)
                Toggle("Open popover with keyboard shortcut", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { _, _ in
                        stopRecording()
                        applyHotkey()
                    }
                if hotkeyEnabled {
                    LabeledContent("Shortcut") {
                        Button(recorder == nil ? hotkeyLabel : "Press keys… (Esc cancels)", action: recordHotkey)
                            .help("Click, then press a combination with ⌘, ⌥ or ⌃")
                    }
                    if HotKey.shared.failed {
                        Text("macOS refused that shortcut. Try another.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in
                        guard on != AppSettings.opensAtLogin else { return }
                        do {
                            try AppSettings.setOpensAtLogin(on)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            opensAtLogin = AppSettings.opensAtLogin
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    HStack {
                        Text(version)
                        Button("Licenses…") {
                            if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .help("Open-source notices, including FFmpeg (LGPL)")
                    }
                }
                Label("Everything runs on this Mac. No network, originals never deleted.", systemImage: "lock.shield")
                    .font(.callout)
                HStack {
                    Text("Finder Quick Actions may need enabling first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Keyboard Shortcuts…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate()
            opensAtLogin = AppSettings.opensAtLogin
            hotkeyFailed = HotKey.shared.failed
        }
        .onDisappear { stopRecording() }
    }

    private func applyHotkey() {
        HotKey.shared.apply()
        hotkeyFailed = HotKey.shared.failed
    }

    private func stopRecording() {
        guard let recorder else { return }
        NSEvent.removeMonitor(recorder)
        self.recorder = nil
        applyHotkey()
    }

    /// Records the next key combo. The current hot key is off meanwhile so pressing it again re-records it.
    private func recordHotkey() {
        guard recorder == nil else { return stopRecording() }
        HotKey.shared.unregister()
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return }
                let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
                guard !flags.isDisjoint(with: [.control, .option, .command]),
                      let typed = event.charactersIgnoringModifiers?.uppercased(), !typed.isEmpty else { return }
                // ⌘-only standard shortcuts would stop working in every app.
                if flags == .command, ["C", "V", "X", "Z", "A", "S", "Q", "W", "N", "O", "P", "F", "H", "M", "\t", " "].contains(typed) {
                    NSSound.beep()
                    return
                }
                var carbon = 0
                var label = ""
                for (flag, bit, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
                                            (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) {
                    carbon |= bit
                    label += symbol
                }
                let defaults = UserDefaults.standard
                let previous = (defaults.integer(forKey: AppSettings.hotkeyKeyCode),
                                defaults.integer(forKey: AppSettings.hotkeyModifiers), hotkeyLabel)
                defaults.set(Int(event.keyCode), forKey: AppSettings.hotkeyKeyCode)
                defaults.set(carbon, forKey: AppSettings.hotkeyModifiers)
                hotkeyLabel = label + (typed == " " ? "Space" : typed)
                stopRecording()
                if HotKey.shared.failed {
                    // Keep the shortcut that worked; the caption says this one was refused.
                    defaults.set(previous.0, forKey: AppSettings.hotkeyKeyCode)
                    defaults.set(previous.1, forKey: AppSettings.hotkeyModifiers)
                    hotkeyLabel = previous.2
                    HotKey.shared.apply()
                }
            }
            return nil
        }
    }

    private func suffixField(_ title: String, text: Binding<String>, example: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(title, text: text, prompt: Text("none"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 140)
                Text(example).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url, (try? AppSettings.replaceOutputFolder(with: url)) != nil else {
            if folder == nil { useFolder = false }
            return
        }
        bookmark = UserDefaults.standard.data(forKey: AppSettings.folderBookmark) ?? Data()
        useFolder = true
    }
}
