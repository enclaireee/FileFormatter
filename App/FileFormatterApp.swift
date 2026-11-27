import SwiftUI

@main
struct FileFormatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        AppSettings.register()
        #if DEBUG
        AppSelfTest.runIfRequested()
        #endif
        #if BENCH
        MemoryBench.runIfRequested()
        #endif
        Task { @MainActor in
            StatusItemController.shared.start()
            #if !BENCH
            _ = Updater.shared  // starts Sparkle's scheduled checks
            #endif
        }
    }

    var body: some Scene {
        WindowGroup("FileFormatter", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1_200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") {
                    model.showImporter = true
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isRunning && model.pdfMode == .merge)

                Button("Add Folder…") {
                    model.showFolderImporter = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.isRunning && model.pdfMode == .merge)
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste Files or Screenshot") {
                    model.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(model.isRunning && model.pdfMode == .merge)
            }
            CommandMenu("Convert") {
                Button("Convert Files") {
                    model.startRun()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canRun)

                Button("Stop") {
                    model.cancel()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isBusy)

                Divider()

                Menu("Apply Preset") {
                    ForEach(Array(Preset.builtIn.prefix(6).enumerated()), id: \.element.id) { idx, preset in
                        Button(preset.name) {
                            model.apply(preset)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                        .disabled(model.isRunning)
                    }
                }

                Divider()

                Button("Clear Queue") {
                    model.clearQueue()
                }
                .disabled(model.items.isEmpty || model.isRunning)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
