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
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var importTypes: [UTType] {
        [
            .folder,
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
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help(showInspector ? "Hide inspector (⌥⌘0)" : "Show inspector (⌥⌘0)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.showImporter = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .disabled(model.isRunning)
                .help("Add files or folders (⌘O)")

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
                        Label(convertTitle, systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRun)
                    .help(model.runBlockedReason ?? "Convert the files (⌘↩). Originals are never changed.")
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
    }

    private var convertTitle: String {
        let count = model.runnableCount
        return count == 0 ? "Convert" : "Convert \(count) File\(count == 1 ? "" : "s")"
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
            if model.isRunning {
                RunProgressBar(model: model)
                Divider()
            }
            if let notice = model.notice {
                NoticeBanner(model: model, notice: notice)
                Divider()
            }
            if model.isEmpty {
                EmptyStateView(model: model, isDropTargeted: isDropTargeted)
            } else {
                QueueView(model: model)
            }
            if !model.isEmpty {
                Divider()
                BottomBar(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .default, value: model.isRunning)
        .animation(reduceMotion ? nil : .default, value: model.notice?.id)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }
}

/// Inline progress while the window queue converts; the toolbar holds Stop.
struct RunProgressBar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Converting \(min(model.completedCount + 1, model.totalToConvert)) of \(model.totalToConvert)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if let name = model.currentItemName {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Stop") { model.cancel() }
                    .controlSize(.small)
                    .help("Stop after the current file. Finished files are kept. (⌘.)")
            }
            ProgressView(value: model.progress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Converting \(model.completedCount) of \(model.totalToConvert) done")
    }
}

/// Result of the last run, a stop, an undo or a hint. Recoverable things live here instead of modal alerts.
struct NoticeBanner: View {
    let model: AppModel
    let notice: AppModel.Notice
    @State private var confirmUndo = false
    @AppStorage(AppSettings.revealWhenDone) private var revealWhenDone = true

    private var symbol: (String, Color) {
        switch notice.tone {
        case .success: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .info: ("info.circle.fill", .secondary)
        }
    }

    private var hasFailures: Bool {
        model.items.contains { if case .failed = $0.status { true } else { false } }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol.0)
                .font(.title3)
                .foregroundStyle(symbol.1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.callout.weight(.semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if let summary = notice.summary {
                if hasFailures, model.lastSummary?.id == summary.id {
                    Button("Retry Failed") { model.retryFailed() }
                }
                if !summary.outputs.isEmpty, !summary.undone {
                    Button("Undo…") { confirmUndo = true }
                        .help("Move the new files to the Trash")
                    // Finder already opened on its own when revealWhenDone is on.
                    let finder = Button("Show in Finder") { model.reveal(summary) }
                    if revealWhenDone { finder } else { finder.buttonStyle(.borderedProminent) }
                }
            }
            Button {
                model.notice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            "Undo this conversion?",
            isPresented: $confirmUndo
        ) {
            Button("Move \(notice.summary?.outputs.count ?? 0) New Files to Trash", role: .destructive) {
                if let summary = notice.summary {
                    Task { await model.undoRun(summary) }
                }
            }
        } message: {
            Text("Your originals aren't touched.")
        }
    }
}

struct BottomBar: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 12) {
            Button {
                openSettings()
            } label: {
                Label("Saved \(model.destinationDescription.prefix(1).lowercased() + model.destinationDescription.dropFirst()) · originals kept", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help("Change where converted files are saved")
            Spacer()
            if model.items.contains(where: { $0.status == .completed }) {
                Button("Clear Finished") { model.clearFinished() }
                    .disabled(model.isRunning)
                    .help("Remove converted files from this list. Undo stays available in History.")
            }
            Button("Rename…") {
                model.showRename = true
            }
            .disabled(model.isEmpty || model.isRunning)
            .help("Batch rename the files in the list")
            Button("Clear All") { model.clearQueue() }
                .disabled(model.isRunning)
                .help("Empty the list. Files on disk aren't touched.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(.bar)
    }
}
