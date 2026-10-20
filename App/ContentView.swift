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
    @State private var showSidebar = true
    @State private var showInspector = true
    @State private var isDropTargeted = false
    @State private var showImageTools = false
    @State private var showPDFTools = false
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
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(model: model, selection: $selection)
                    .frame(width: 230)
                    .frame(maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .leading))

                Divider()
            }

            HStack(spacing: 0) {
                detail

                if showInspector {
                    Divider()

                    InspectorView(model: model)
                        .frame(width: 330)
                        .frame(maxHeight: .infinity)
                        .background(Theme.Palette.canvas)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle("FileFormatter")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                        showSidebar.toggle()
                    }
                } label: {
                    Label("Sidebar", systemImage: "sidebar.leading")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(showSidebar ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                        showInspector.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help(showInspector ? "Hide inspector (⌥⌘0)" : "Show inspector (⌥⌘0)")

                Menu {
                    Button {
                        showImageTools = true
                    } label: {
                        Label("Image Tools…", systemImage: "crop.rotate")
                    }
                    Button {
                        showPDFTools = true
                    } label: {
                        Label("PDF Tools…", systemImage: "doc.richtext")
                    }
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .disabled(model.isBusy)
                .help("Rotate, crop, organize PDFs, and more")

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
        .sheet(isPresented: $showImageTools) {
            ImageToolsSheet(model: model, urls: toolURLs(for: .image))
        }
        .sheet(isPresented: $showPDFTools) {
            PDFToolsSheet(model: model, urls: toolURLs(for: .pdf))
        }
    }

    /// Selected rows of one kind, or every row of that kind when nothing is selected.
    private func toolURLs(for kind: FileKind) -> [URL] {
        let selected = model.items.filter { model.selection.contains($0.id) && $0.kind == kind }
        let matching = selected.isEmpty ? model.items.filter { $0.kind == kind } : selected
        return matching.map(\.sourceURL)
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
            HistoryView(model: model)
        }
    }

    private var queueDetail: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if model.isEmpty {
                    EmptyStateView(model: model, isDropTargeted: isDropTargeted)
                } else {
                    QueueView(model: model)
                    BottomBar(model: model)
                }
            }

            if let notice = model.notice {
                NoticeToast(model: model, notice: notice)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, model.isEmpty ? Theme.Space.xl : 54)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: model.notice?.id)
    }
}

/// Result of the last run, a stop, an undo or a hint. It floats above the queue
/// instead of pushing the table down, so the working surface never jumps.
struct NoticeToast: View {
    let model: AppModel
    let notice: AppModel.Notice
    @State private var confirmUndo = false
    @AppStorage(AppSettings.revealWhenDone) private var revealWhenDone = true

    private var symbol: String {
        switch notice.tone {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tone: Theme.Tone {
        switch notice.tone {
        case .success: .success
        case .warning: .warning
        case .info: .info
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            IconTile(systemImage: symbol, tone: tone, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = notice.summary {
                    actions(for: summary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: Theme.Space.sm)

            Button {
                model.notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss result")
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
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

    @ViewBuilder
    private func actions(for summary: RunSummary) -> some View {
        HStack(spacing: Theme.Space.md) {
            if notice.retryable {
                Button("Retry Failed") { model.retryFailed() }
                    .controlSize(.small)
            }

            if !summary.outputs.isEmpty, !summary.undone {
                if revealWhenDone {
                    Button("Show in Finder") { model.reveal(summary) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else {
                    Button("Show in Finder") { model.reveal(summary) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                Button("Undo…") { confirmUndo = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Move the new files to the Trash")
            }
        }
    }
}

struct BottomBar: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    private var finishedCount: Int {
        model.items.filter { $0.status == .completed }.count
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                openSettings()
            } label: {
                Label(model.destinationDescription, systemImage: "folder")
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help("Change where converted files are saved")

            Spacer(minLength: Theme.Space.md)

            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected")
                    .monospacedDigit()
                Button("Remove") { model.removeSelected() }
                    .disabled(model.isRunning)
                    .help("Remove the selected files from this list. Files on disk aren't touched.")
                Divider()
                    .frame(height: 14)
            }

            Button("Rename…") {
                model.showRename = true
            }
            .disabled(model.isEmpty || model.isRunning)
            .help("Batch rename the files in the list")

            Menu {
                Button("Clear Finished") { model.clearFinished() }
                    .disabled(model.isRunning || finishedCount == 0)
                Button("Clear All", role: .destructive) { model.clearQueue() }
                    .disabled(model.isRunning)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Clear the list")
            .accessibilityLabel("More queue actions")
        }
        .font(Theme.Text.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }
}
