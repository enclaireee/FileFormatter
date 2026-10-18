import SwiftUI

@main
struct FileFormatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        #if DEBUG
        AppSelfTest.runIfRequested()
        #endif
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

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label("FileFormatter", systemImage: "arrow.triangle.2.circlepath")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isEmpty ? "No files queued" : "\(model.items.count) files · \(model.runnableCount) ready")
        if model.isRunning {
            Text("Converting \(model.completedCount)/\(model.totalToConvert)…")
            Button("Cancel") {}
                .disabled(true)
        } else {
            Button("Convert Queue") {
                Task { await model.run() }
            }
            .disabled(model.runnableCount == 0)
        }
        Divider()
        Button("Open FileFormatter") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Add Files…") {
            openWindow(id: "main")
            model.showImporter = true
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit FileFormatter") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
