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

    func stage(_ new: [URL]) {
        summary = nil
        error = nil
        configuring = nil
        urls = new
    }

    /// Keep the current batch and add more files to it.
    func append(_ new: [URL]) {
        summary = nil
        error = nil
        configuring = nil
        var seen = Set(urls.map(\.path))
        urls += new.filter { seen.insert($0.path).inserted }
    }

    func reset() {
        urls = []
        configuring = nil
        summary = nil
        error = nil
    }
}

struct QuickConvertView: View {
    let state: QuickConvertState
    let model: AppModel
    var reopen: () -> Void = {}
    @State private var targeted = false
    @AppStorage(AppSettings.revealWhenDone) private var revealWhenDone = true

    private var running: Bool { model.isQuickRunning || state.isStarting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if running { runningView }
                else if let summary = state.summary { doneView(summary) }
                else if state.urls.isEmpty { emptyView }
                else { stagedView }
            }
            .padding(14)

            Hairline()

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 380)
        .background(targeted ? Theme.Palette.accent.opacity(0.05) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard !running else { return false }
            state.stage(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted = $0 }
    }

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: Theme.Space.md) {
            VStack(spacing: 7) {
                IconTile(systemImage: "square.and.arrow.down", tone: .accent, size: 46)
                Text("Drop files here")
                    .font(.headline)
                Text("Convert without opening the main window.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 118)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(targeted ? Theme.Palette.accent.opacity(0.08) : Color.primary.opacity(0.025))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(
                        targeted ? Theme.Palette.accent : Theme.Palette.hairline,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }

            HStack(spacing: Theme.Space.sm) {
                Button("Choose Files…") { choose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Text("or drag them here")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
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
        state.urls.reduce(0) { total, url in
            total + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
                state.summary = summary
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
                ProgressView(value: Double(done), total: Double(total))
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
                Button("Copy") {
                    let existing = summary.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(existing as [NSURL])
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
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .help("Drag into any app")
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
        let output = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isRunning {
                Text("Main window: converting \(model.completedCount) of \(model.totalToConvert)")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open FileFormatter") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
                    }
                }
                .buttonStyle(.borderless)

                Spacer()

                Menu {
                    SettingsLink { Text("Settings…") }
                    Button("Check for Updates…") { Updater.shared.checkNow() }
                        .disabled(!Updater.shared.canCheck)
                    if model.isRunning {
                        Button("Stop Queue") { model.cancel() }
                    } else if model.runnableCount > 0 {
                        Button("Convert Queue") { model.startRun() }
                    }
                    Divider()
                    Button("Quit FileFormatter") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Settings and quit")
                .help("Settings and Quit")
            }
            .font(Theme.Text.caption)
        }
    }
}
