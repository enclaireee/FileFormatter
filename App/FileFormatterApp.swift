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
        Task { @MainActor in
            StatusItemController.shared.start()
            _ = Updater.shared  // starts Sparkle's scheduled checks
        }
    }

    var body: some Scene {
        WindowGroup("FileFormatter", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files or Folders…") {
                    model.showImporter = true
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isRunning)
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
