import AppKit
import FileFormatterCore
import QuickLook
import SwiftUI

struct QueueView: View {
    @Bindable var model: AppModel
    @State private var previewURL: URL?
    @State private var search = ""

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [ConversionItem] {
        guard !query.isEmpty else { return model.items }
        return model.items.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.outputName.localizedCaseInsensitiveContains(query)
        }
    }

    private var sourceURLs: [URL] {
        var seen = Set<URL>()
        return model.items.map(\.sourceURL).filter { seen.insert($0).inserted }
    }

    private var hasAttention: Bool {
        !model.warnings.isEmpty || !model.unsupportedIDs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                searchBar
                Spacer(minLength: 0)
            }
            if model.isRunning {
                progress
            }
            if hasAttention {
                attention
            }
            table
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.tertiary)

            TextField("Filter files", text: $search)
                .textFieldStyle(.plain)
                .font(Theme.Text.body)

            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.hairline.opacity(0.55), lineWidth: 1)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.sm)
    }

    // MARK: Header

    private var header: some View {
        PageHeader("Conversion queue", subtitle: subtitle) {
            HStack(spacing: Theme.Space.sm) {
                if model.isPlanning || model.isQuickRunning {
                    ProgressView()
                        .controlSize(.small)
                        .help(model.isPlanning ? "Reading the files…" : "Running a quick action…")
                }
                quickActions
            }
        }
    }

    private var subtitle: String {
        let count = model.items.count
        var parts = ["\(count) file\(count == 1 ? "" : "s")", ByteCount.string(model.inputBytes)]

        if model.isPlanning {
            parts.append("Preparing…")
        } else if model.isRunning {
            parts.append("Converting \(min(model.completedCount + 1, model.totalToConvert)) of \(model.totalToConvert)")
        } else if model.isQuickRunning {
            parts.append("Running quick action")
        } else {
            let pending = model.count { $0 == .pending }
            let completed = model.count { $0 == .completed }
            let skipped = model.count { if case .skipped = $0 { true } else { false } }
            let failed = model.count { if case .failed = $0 { true } else { false } }

            if pending > 0, pending < count { parts.append("\(pending) ready") }
            if completed > 0 { parts.append("\(completed) done") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if failed > 0 { parts.append("\(failed) failed") }
        }

        return parts.joined(separator: " · ")
    }

    private var quickActions: some View {
        let urls = sourceURLs
        let others = QuickAction.otherFormats(for: urls)
        return Menu {
            ForEach(QuickAction.suggestions(for: urls)) { action in
                Button(action.title, systemImage: action.systemImage) { run(action, urls) }
            }
            if !others.isEmpty {
                Menu("Other formats") {
                    ForEach(others) { action in
                        Button(action.title) { run(action, urls) }
                    }
                }
            }
        } label: {
            Label("Quick Actions", systemImage: "bolt.horizontal")
        }
        .help("Run one action on these files without changing the queue settings")
        .fixedSize()
        .disabled(model.isRunning || model.isQuickRunning || urls.isEmpty)
    }

    private func run(_ action: QuickAction, _ urls: [URL]) {
        Task {
            if let summary = await model.quickRun(urls: urls, action: action, showsProgress: true) {
                model.showResult(summary)
            }
        }
    }

    // MARK: Live state

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.sm) {
                Text("Converting \(min(model.completedCount + 1, model.totalToConvert)) of \(model.totalToConvert)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if let name = model.currentItemName {
                    Text(name)
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Theme.Space.sm)
                Text("\(Int(model.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Converting \(model.completedCount) of \(model.totalToConvert) files")
    }

    private var attention: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.Palette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if !model.warnings.isEmpty {
                    Text(model.warnings.joined(separator: " "))
                        .lineLimit(2)
                }
                if !model.unsupportedIDs.isEmpty {
                    Text("\(model.unsupportedIDs.count) file\(model.unsupportedIDs.count == 1 ? "" : "s") can't be converted with these settings.")
                }
            }
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Space.sm)

            if !model.unsupportedIDs.isEmpty {
                Button("Remove Unsupported") { model.remove(model.unsupportedIDs) }
                    .controlSize(.small)
                    .disabled(model.isRunning)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        .background(Theme.Palette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, 10)
    }

    // MARK: Table

    private var table: some View {
        Table(filteredItems, selection: $model.selection) {
            TableColumn("File") { item in
                HStack(spacing: 9) {
                    IconTile(systemImage: icon(for: item.kind), size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(subtitle(for: item)) · \(ByteCount.string(item.byteSize))")
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 1)
                .help(item.note ?? item.sourceURL.path)
                .accessibilityElement(children: .combine)
            }
            .width(min: 190, ideal: 230)

            TableColumn("Becomes") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.outputName)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(item.fidelity == .unsupported ? .secondary : .primary)
                        .help(item.outputName)
                    if let line = secondaryLine(for: item) {
                        Text(line)
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(item.fidelity.explanation)
                    }
                }
                .padding(.vertical, 1)
            }
            .width(min: 150, ideal: 190)

            TableColumn("Status") { item in
                StatusBadge(status: item.status)
            }
            .width(min: 90, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .onDeleteCommand { model.removeSelected() }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            for url in urls(for: ids) { NSWorkspace.shared.open(url) }
        }
        .quickLookPreview($previewURL, in: model.items.map { $0.outputURL ?? $0.sourceURL })
        .onKeyPress(.space) {
            guard let id = model.selection.first,
                  let item = model.items.first(where: { $0.id == id }) else { return .ignored }
            previewURL = item.outputURL ?? item.sourceURL
            return .handled
        }
        .overlay {
            if filteredItems.isEmpty, !query.isEmpty {
                ContentUnavailableView(
                    "No matching files",
                    systemImage: "magnifyingglass",
                    description: Text("Try another name, or clear the filter.")
                )
                .background(Theme.Palette.canvas.opacity(0.96))
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let picked = model.items.filter { ids.contains($0.id) }
        if !picked.isEmpty {
            Button("Show in Finder") {
                let urls = picked.map { $0.outputURL ?? $0.sourceURL }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Button("Open") {
                for item in picked { NSWorkspace.shared.open(item.outputURL ?? item.sourceURL) }
            }
            if picked.contains(where: { $0.outputURL != nil }) {
                Button("Copy Output Path") {
                    let paths = picked.compactMap(\.outputURL).map(\.path).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(paths, forType: .string)
                }
            }
            if picked.contains(where: { if case .failed = $0.status { true } else { false } }) {
                Button("Retry Failed") { model.retryFailed() }
                    .disabled(model.isRunning)
            }
            Divider()
            Button("Remove", role: .destructive) { model.remove(ids) }
                .disabled(model.isRunning)
        }
    }

    private func urls(for ids: Set<UUID>) -> [URL] {
        model.items.filter { ids.contains($0.id) }.map { $0.outputURL ?? $0.sourceURL }
    }

    private func secondaryLine(for item: ConversionItem) -> String? {
        if item.fidelity == .unsupported { return "Can't convert" }
        if case .completed = item.status, let out = model.outputSizes[item.id] {
            var text = ByteCount.string(out)
            if item.byteSize > 0 {
                let change = (Double(out) - Double(item.byteSize)) / Double(item.byteSize) * 100
                let rounded = Int(change.rounded())
                text += " · " + (rounded > 0 ? "+\(rounded)%" : rounded < 0 ? "\u{2212}\(-rounded)%" : "0%")
            }
            return text
        }
        switch item.fidelity {
        case .lossy: return "Lossy"
        case .extract: return "Extracts text"
        case .reencode: return "Re-encoded"
        default: return nil
        }
    }

    private func subtitle(for item: ConversionItem) -> String {
        if let page = item.pageIndex {
            return "PDF · page \(page) of \(item.pageCount ?? page)"
        }
        return item.kind.label
    }

    private func icon(for kind: FileKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .data: "tablecells"
        case .archive: "archivebox"
        case .unknown: "doc"
        }
    }
}
