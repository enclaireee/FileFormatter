import SwiftUI

@main
struct FileFormatterApp: App {
    @State private var model = AppModel()

    init() {
        #if DEBUG
        AppSelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
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
                    Task { await model.run() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isRunning || model.runnableCount == 0)

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
