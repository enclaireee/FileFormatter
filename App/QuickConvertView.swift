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
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if running { runningView }
                else if let summary = state.summary { doneView(summary) }
                else if state.urls.isEmpty { emptyView }
                else { stagedView }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .dropDestination(for: URL.self) { urls, _ in
            guard !running else { return false }
            state.stage(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted = $0 }
    }

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Drop files here")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(targeted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    .strokeBorder(targeted ? Color.accentColor : Color.secondary,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            Button("Choose Files…", action: choose)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // The transient popover may close when the panel takes focus; state survives, so reopen after.
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            state.stage(panel.urls)
            reopen()
        }
    }

    // MARK: Staged

    private var stagedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.urls.prefix(4), id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(url.lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if state.urls.count > 4 {
                        Text("+\(state.urls.count - 4) more").foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { state.reset() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Esc clears; the Compress panel's Back owns Esc while it is open.
                .keyboardShortcut(state.configuring == nil ? .cancelAction : nil)
                .accessibilityLabel("Clear files")
                .help("Clear files (Esc)")
            }
            if let error = state.error {
                HStack(alignment: .firstTextBaseline) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    if let job = state.lastJob {
                        Button("Try Again") { start(job) }.controlSize(.small)
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

    private func run(_ action: QuickAction) {
        switch action {
        case .compressImage, .compressPDF, .compressVideo: state.configuring = action
        default: start(action.job(for: state.urls))
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
        VStack(alignment: .leading, spacing: 8) {
            if !model.quickItems.isEmpty {
                let total = model.quickItems.count
                let done = model.quickItems.filter(\.status.isTerminal).count
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("Converting \(min(done + 1, total)) of \(total)").font(.caption)
                }
            }
            ForEach(model.quickItems.prefix(6)) { item in
                HStack(spacing: 8) {
                    statusIcon(item.status)
                    Text(item.sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
            }
            if model.quickItems.count > 6 {
                Text("+\(model.quickItems.count - 6) more").foregroundStyle(.secondary)
            }
            if model.quickItems.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Preparing…") }
            }
            Button("Stop") { model.cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private func statusIcon(_ status: ItemStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        case .converting: ProgressView().controlSize(.small).accessibilityLabel("Converting")
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.orange).accessibilityLabel("Skipped")
        }
    }

    // MARK: Done

    private func doneView(_ summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if summary.undone {
                Label("Undone", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.headline).foregroundStyle(.secondary)
            } else if summary.converted == 0 {
                Label("Nothing was converted", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
            } else {
                Label("\(summary.converted) converted", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            }
            if summary.skipped > 0 { Text("\(summary.skipped) skipped").foregroundStyle(.orange) }
            if summary.failed > 0 { Text("\(summary.failed) failed").foregroundStyle(.red) }
            if !summary.undone {
                outputRows
            }
            ForEach(Array(problems.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
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
                // Finder already opened on its own; keep a quiet button for when that window is gone.
                if revealWhenDone { finder.buttonStyle(.borderless) } else { finder }
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
            }
            if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Button("Convert more") { state.reset() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Converted files with their sizes; drag a row into any app to hand the file over.
    @ViewBuilder private var outputRows: some View {
        let done = model.quickItems.filter { $0.outputURL != nil && $0.status == .completed }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(done.prefix(5)) { item in
                if let url = item.outputURL {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(sizeChange(from: item.byteSize, to: url))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .help("Drag into any app")
                }
            }
            if done.count > 5 {
                Text("+\(done.count - 5) more").font(.caption).foregroundStyle(.secondary)
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
            case .failed(let m), .skipped(let m): "\(item.sourceURL.lastPathComponent): \(m)"
            default: nil
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isRunning {
                Text("Main window: converting \(model.completedCount) of \(model.totalToConvert)")
                    .font(.caption).foregroundStyle(.secondary)
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
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Settings and quit")
                .help("Settings and Quit")
            }
        }
    }
}
