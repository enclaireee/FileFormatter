import FileFormatterCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case queue
    case watchFolders
    case duplicates
    case history
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarSelection? = .queue
    @State private var showInspector = true

    private var importTypes: [UTType] {
        [
            .image,
            .pdf,
            .audio,
            .movie,
            .commaSeparatedText,
            UTType(filenameExtension: "tsv") ?? .text,
            .json,
            UTType(filenameExtension: "yaml") ?? .data,
            UTType(filenameExtension: "toml") ?? .data,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "pptx") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "xls") ?? .data,
            UTType(filenameExtension: "flac") ?? .audio,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie,
            UTType(filenameExtension: "opus") ?? .audio
        ]
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection)
        } detail: {
            detail
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
                }
        }
        .navigationTitle("FileFormatter")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide inspector" : "Show inspector")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(model.completedCount)/\(model.totalToConvert)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.showImporter = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .help("Add files (⌘O)")

                if model.isRunning {
                    Button(role: .cancel) {
                        model.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop after the current file (⌘.)")
                } else {
                    Button {
                        model.startRun()
                    } label: {
                        Label("Convert \(model.runnableCount)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runnableCount == 0)
                    .help("Convert the queue (⌘↩)")
                }
            }
        }
        .fileImporter(
            isPresented: $model.showImporter,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.addFiles(urls)
            case .failure(let error):
                model.present(error: error)
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $model.showRename) {
            RenameSheet(model: model)
        }
        .sheet(isPresented: $model.showCompletion) {
            CompletionSheet(model: model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .queue {
        case .queue:
            queueDetail
        case .watchFolders:
            WatchFoldersView(model: model)
        case .duplicates:
            DuplicatesView()
        case .history:
            HistoryView()
        }
    }

    private var queueDetail: some View {
        VStack(spacing: 0) {
            if model.isEmpty {
                EmptyStateView(model: model)
            } else {
                QueueView(model: model)
            }
            Divider()
            BottomBar(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        }
    }
}

struct BottomBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Label("Keep originals", systemImage: "checkmark.shield")
            Text("Same folder · \(model.suffix)")
            Spacer()
            if !model.isEmpty {
                Text("\(model.items.count) files · \(ByteCount.string(model.inputBytes))")
                    .monospacedDigit()
            }
            Button("Rename…") {
                model.showRename = true
            }
            .disabled(model.isEmpty || model.isRunning)
            .help("Batch rename the files in the queue")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(.bar)
    }
}
