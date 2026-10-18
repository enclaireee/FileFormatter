import SwiftUI

@main
struct FileFormatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        #if DEBUG
        AppSelfTest.runIfRequested()
        #endif
        Task { @MainActor in StatusItemController.shared.start() }
    }

    var body: some Scene {
        WindowGroup("FileFormatter", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") {
                    model.showImporter = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Convert") {
                Button("Convert Files") {
                    model.startRun()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isRunning || model.runnableCount == 0)

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
