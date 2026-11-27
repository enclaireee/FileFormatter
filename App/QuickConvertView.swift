import AppKit
import FileFormatterCore
import SwiftUI

/// Files staged in the popover; shared between the status item's drop handler and the view.
@MainActor @Observable
final class QuickConvertState {
    var urls: [URL] = []
    var summary: RunSummary?
    var isStarting = false
    var undoing = false
    var error: String?
    /// The last job started, so a failure can offer Try Again.
    var lastJob: ConversionJob?
    /// A Compress action waiting on its options panel.
    var configuring: QuickAction?

    /// Cached metadata for staged URLs so SwiftUI views don't hit disk/Finder on every redraw.
    private(set) var cachedTotalSize: UInt64 = 0
    private(set) var cachedIcons: [URL: NSImage] = [:]
    private(set) var cachedOutputSizes: [URL: UInt64] = [:]

    func stage(_ new: [URL]) {
        summary = nil
        error = nil
        configuring = nil
        urls = new
        refreshMetadata(for: new)
    }

    /// Keep the current batch and add more files to it.
    func append(_ new: [URL]) {
        summary = nil
        error = nil
        configuring = nil
        var seen = Set(urls.map(\.path))
        let added = new.filter { seen.insert($0.path).inserted }
        urls += added
        refreshMetadata(for: urls)
    }

    func recordSummary(_ runSummary: RunSummary?) {
        summary = runSummary
        guard let runSummary else {
            cachedOutputSizes = [:]
            return
        }
        var sizes: [URL: UInt64] = [:]
        for url in runSummary.outputs {
            sizes[url] = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        cachedOutputSizes = sizes
    }

    private func refreshMetadata(for targetURLs: [URL]) {
        var icons: [URL: NSImage] = [:]
        for url in targetURLs.prefix(6) {
            icons[url] = NSWorkspace.shared.icon(forFile: url.path)
        }
        cachedIcons = icons
        Task.detached(priority: .userInitiated) { [weak self] in
            let bytes = targetURLs.reduce(UInt64(0)) { total, url in
                total + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            await MainActor.run {
                guard let self, self.urls == targetURLs else { return }
                self.cachedTotalSize = bytes
            }
        }
    }

    func reset() {
        urls = []
        configuring = nil
        summary = nil
        error = nil
        cachedTotalSize = 0
        cachedIcons = [:]
        cachedOutputSizes = [:]
    }
}

struct QuickConvertView: View {
    let state: QuickConvertState
    let model: AppModel
    var reopen: () -> Void = {}
    @State private var targeted = false
    @State private var canPaste = false
    @State private var copiedFeedback = false
    @AppStorage(AppSettings.revealWhenDone) private var revealWhenDone = true
    @AppStorage(AppSettings.useFolder) private var useFolder = false

    private var running: Bool { model.isQuickRunning || state.isStarting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 9)

            Hairline()

            Group {
                if running { runningView }
                else if let summary = state.summary { doneView(summary) }
                else if state.urls.isEmpty { emptyView }
                else { stagedView }
            }
            .padding(14)

            if model.isRunning {
                Hairline()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Main window: converting \(model.completedCount) of \(model.totalToConvert)")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 360)
        .background(targeted ? Theme.Palette.accent.opacity(0.05) : Color.clear)
        .onAppear {
            canPaste = ClipboardImport.hasPasteableContent()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !running else { return false }
            state.stage(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted = $0 }
        // Hidden shortcut receiver so ⌘V works anywhere in the popover.
        .background {
            Button("") { pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func pasteFromClipboard() {
        guard !running else { return }
        let urls = ClipboardImport.pasteURLs()
        guard !urls.isEmpty else { return }
        if state.urls.isEmpty || state.summary != nil {
            state.stage(urls)
        } else {
            state.append(urls)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                openMainWindow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("FileFormatter")
                        .font(.callout.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .help("Open main window")

            Spacer(minLength: 4)

            Menu {
                Button {
                    useFolder = false
                } label: {
                    if !useFolder { Label("Next to original", systemImage: "checkmark") }
                    else { Text("Next to original") }
                }
                Button("Choose Output Folder…") {
                    chooseOutputFolder()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(shortDestination)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Where converted files are saved")

            Menu {
                Button("Open Full Window") { openMainWindow() }
                Divider()
                SettingsLink { Text("Settings…") }
                Button("Check for Updates…") { Updater.shared.checkNow() }
                    .disabled(!Updater.shared.canCheck)
                if model.isRunning {
                    Button("Stop Window Queue") { model.cancel() }
                } else if model.runnableCount > 0 {
                    Button("Convert Window Queue") { model.startRun() }
                }
                Divider()
                Button("Quit FileFormatter") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More options")
            .help("Settings, full window, and Quit")
        }
    }

    private var shortDestination: String {
        if useFolder, let folder = AppSettings.outputFolder() {
            return folder.lastPathComponent
        }
        return "Same folder"
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url, (try? AppSettings.replaceOutputFolder(with: url)) != nil {
            useFolder = true
        }
        reopen()
    }

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: Theme.Space.md) {
            VStack(spacing: 10) {
                IconTile(systemImage: targeted ? "arrow.down.doc.fill" : "square.and.arrow.down", tone: .accent, size: 44)
                VStack(spacing: 3) {
                    Text(targeted ? "Release to stage files" : "Drop files or folders")
                        .font(.headline)
                    Text("1-click convert, compress, or remove background.")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    Button("Choose Files…") { choose() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .keyboardShortcut(.defaultAction)

                    if canPaste {
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .controlSize(.regular)
                        .help("Paste copied files or screenshot (⌘V)")
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(targeted ? Theme.Palette.accent.opacity(0.08) : Color.primary.opacity(0.025))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(
                        targeted ? Theme.Palette.accent : Theme.Palette.hairline,
                        style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [6, 4])
                    )
            }

            if let recent = model.quickSummary ?? model.lastSummary, recent.converted > 0, !recent.undone {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.success)
                        .font(.caption)
                    Text("Last: \(recent.converted) file\(recent.converted == 1 ? "" : "s") (\(recent.target))")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !recent.outputs.isEmpty {
                        Button("Finder") {
                            let existing = recent.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
                            if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
                        }
                        .buttonStyle(.link)
                        .font(Theme.Text.caption)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func choose(append: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // The transient popover may close when the panel takes focus; state survives, so reopen after.
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            if append {
                state.append(panel.urls)
            } else {
                state.stage(panel.urls)
            }
            reopen()
        }
    }

    // MARK: Staged

    private var stagedView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(state.urls.count) file\(state.urls.count == 1 ? "" : "s")")
                        .font(.headline)
                    Text("\(ByteCount.string(totalSize)) · originals kept")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.sm)
                Button("Add…") { choose(append: true) }
                    .controlSize(.small)
                Button {
                    state.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Esc clears; the Compress panel's Back owns Esc while it is open.
                .keyboardShortcut(state.configuring == nil ? .cancelAction : nil)
                .accessibilityLabel("Clear files")
                .help("Clear files (Esc)")
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.urls.prefix(4), id: \.self) { url in
                    fileRow(url)
                }
                if state.urls.count > 4 {
                    Text("+\(state.urls.count - 4) more")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                }
            }

            if let error = state.error {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.xs)
                    if let job = state.lastJob {
                        Button("Try Again") { start(job) }
                            .controlSize(.small)
                    }
                }
            }

            if let action = state.configuring {
                CompressPanel(action: action, urls: state.urls) {
                    state.configuring = nil
                } run: { job in
                    state.configuring = nil
                    start(job)
                }
            } else {
                QuickActionRow(urls: state.urls) { run($0) }
            }
        }
    }

    private var totalSize: UInt64 {
        state.cachedTotalSize
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: state.cachedIcons[url] ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(url.lastPathComponent)
                .font(Theme.Text.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
        }
    }

    private func run(_ action: QuickAction) {
        switch action {
        case .compressImage, .compressPDF, .compressVideo:
            state.configuring = action
        default:
            start(action.job(for: state.urls))
        }
    }

    private func start(_ job: ConversionJob) {
        let urls = state.urls
        state.lastJob = job
        state.error = nil
        state.isStarting = true
        Task {
            let summary = await model.quickRun(urls: urls, job: job)
            state.isStarting = false
            if let summary {
                state.recordSummary(summary)
            } else {
                state.error = "Couldn't convert these files. Try another action or open FileFormatter for details."
            }
        }
    }

    // MARK: Running

    private var runningView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            let total = max(model.quickItems.count, 1)
            let done = model.quickItems.filter(\.status.isTerminal).count
            let activePartial = model.quickItems.first(where: { $0.status == .converting })?.progress ?? 0

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Converting")
                        .font(.headline)
                    Spacer()
                    if !model.quickItems.isEmpty {
                        Text("\(min(done + 1, total)) of \(total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: min(Double(total), Double(done) + activePartial), total: Double(total))
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.quickItems.prefix(6)) { item in
                    HStack(spacing: Theme.Space.sm) {
                        statusIcon(item.status)
                        Text(item.sourceURL.lastPathComponent)
                            .font(Theme.Text.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if item.status == .converting, let p = item.progress, p > 0, p < 1 {
                            Text("\(Int((p * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if model.quickItems.count > 6 {
                    Text("+\(model.quickItems.count - 6) more")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                }
                if model.quickItems.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Preparing…")
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Stop") { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
        }
    }

    @ViewBuilder private func statusIcon(_ status: ItemStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting")
        case .converting:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Converting")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.success)
                .accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.Palette.danger)
                .accessibilityLabel("Failed")
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(Theme.Palette.warning)
                .accessibilityLabel("Skipped")
        }
    }

    // MARK: Done

    private func doneView(_ summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                IconTile(
                    systemImage: summary.undone ? "arrow.uturn.backward" : summary.converted == 0 ? "exclamationmark.triangle.fill" : "checkmark",
                    tone: summary.undone ? .neutral : summary.converted == 0 ? .warning : .success,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.undone ? "Undone" : summary.converted == 0 ? "Nothing was converted" : "\(summary.converted) converted")
                        .font(.headline)
                    if !summary.undone {
                        Text(summaryLine(summary))
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if summary.skipped > 0 || summary.failed > 0 {
                HStack(spacing: 5) {
                    if summary.skipped > 0 {
                        Badge(text: "\(summary.skipped) skipped", tone: .warning)
                    }
                    if summary.failed > 0 {
                        Badge(text: "\(summary.failed) failed", tone: .danger)
                    }
                }
            }

            if !summary.undone {
                outputRows
            }

            ForEach(Array(problems.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: Theme.Space.md) {
                Button {
                    let existing = summary.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(existing as [NSURL])
                    copiedFeedback = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        copiedFeedback = false
                    }
                } label: {
                    Label(copiedFeedback ? "Copied" : "Copy", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                }
                .disabled(summary.undone || summary.outputs.isEmpty)
                .help("Copy the files, then paste into Mail, Slack or Finder")

                let finder = Button("Show in Finder") {
                    let existing = summary.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
                }
                .disabled(summary.undone || summary.outputs.isEmpty)

                if revealWhenDone {
                    finder.buttonStyle(.borderless)
                } else {
                    finder
                }

                Button("Undo") {
                    state.undoing = true
                    Task {
                        let result = await model.undo(summary)
                        if result.failed == 0 {
                            state.summary?.undone = true
                        } else {
                            state.error = "\(result.failed) file(s) could not be undone; they may have been moved."
                        }
                        state.undoing = false
                    }
                }
                .disabled(summary.undone || state.undoing || summary.converted == 0)
                .help("Move the new files to the Trash")
            }
            .controlSize(.small)

            if let error = state.error {
                Text(error)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }

            Button("Convert more") { state.reset() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func summaryLine(_ summary: RunSummary) -> String {
        if summary.bytesSaved > 0 {
            return "\(ByteCount.string(UInt64(summary.bytesSaved))) saved"
        }
        return "\(ByteCount.string(summary.outputBytes)) written"
    }

    /// Converted files with their sizes; drag a row into any app to hand the file over.
    @ViewBuilder private var outputRows: some View {
        let done = model.quickItems.filter { $0.outputURL != nil && $0.status == .completed }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(done.prefix(5)) { item in
                if let url = item.outputURL {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        Text(url.lastPathComponent)
                            .font(Theme.Text.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Space.xs)
                        Text(sizeChange(from: item.byteSize, to: url))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .help("Click to reveal in Finder · Drag into any app")
                }
            }
            if done.count > 5 {
                Text("+\(done.count - 5) more")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sizeChange(from input: UInt64, to url: URL) -> String {
        let output = state.cachedOutputSizes[url]
            ?? UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if input > 0, output < input {
            let pct = Int(((1.0 - Double(output) / Double(input)) * 100).rounded())
            if pct > 0 {
                return "\(CompressPanel.format(output)) (\u{2212}\(pct)%)"
            }
        }
        return "\(CompressPanel.format(input)) → \(CompressPanel.format(output))"
    }

    private var problems: [String] {
        model.quickItems.compactMap { item in
            switch item.status {
            case .failed(let message), .skipped(let message):
                "\(item.sourceURL.lastPathComponent): \(message)"
            default:
                nil
            }
        }
    }
}
