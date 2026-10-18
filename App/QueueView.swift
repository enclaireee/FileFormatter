import AppKit
import FileFormatterCore
import QuickLook
import SwiftUI

struct QueueView: View {
    @Bindable var model: AppModel
    @State private var previewURL: URL?
    @State private var search = ""

    private var filteredItems: [ConversionItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard model.items.count > 20, !query.isEmpty else { return model.items }
        return model.items.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var sourceURLs: [URL] {
        var seen = Set<URL>()
        return model.items.map(\.sourceURL).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.warnings.isEmpty {
                warningBanner
            }
            if !model.unsupportedIDs.isEmpty {
                unsupportedRow
            }
            Divider()
            table
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleLine)
                    .font(.headline)
                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.isPlanning {
                ProgressView()
                    .controlSize(.small)
            }
            quickActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var titleLine: String {
        let n = model.items.count
        return "\(n) file\(n == 1 ? "" : "s") · \(ByteCount.string(model.inputBytes))"
    }

    private var statusLine: String {
        let parts = [
            (model.count { $0 == .pending }, "ready"),
            (model.count { $0 == .completed }, "done"),
            (model.count { if case .skipped = $0 { true } else { false } }, "skipped"),
            (model.count { if case .failed = $0 { true } else { false } }, "failed"),
        ]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    private var quickActions: some View {
        let urls = sourceURLs
        let others = QuickAction.otherFormats(for: urls)
        return Menu("Quick Actions") {
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
        }
        .help("Run now on these files")
        .fixedSize()
        .disabled(model.isRunning || urls.isEmpty)
    }

    private func run(_ action: QuickAction, _ urls: [URL]) {
        Task {
            if let summary = await model.quickRun(urls: urls, action: action, showsProgress: true) {
                model.showResult(summary)
            }
        }
    }

    private var warningBanner: some View {
        Label(model.warnings.joined(separator: " "), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    private var unsupportedRow: some View {
        let n = model.unsupportedIDs.count
        return HStack {
            Text("\(n) file\(n == 1 ? "" : "s") can't be converted")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Remove Unsupported") { model.remove(model.unsupportedIDs) }
                .disabled(model.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Table

    private var table: some View {
        Table(filteredItems, selection: $model.selection) {
            TableColumn("File") { item in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: item.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(subtitle(for: item)) · \(ByteCount.string(item.byteSize))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(item.note ?? item.sourceURL.path)
                .accessibilityElement(children: .combine)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Becomes") { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.outputName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.fidelity == .unsupported ? .secondary : .primary)
                    if let line = secondaryLine(for: item) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(item.fidelity.explanation)
                    }
                }
            }
            .width(min: 150, ideal: 220)

            TableColumn("Status") { item in
                StatusBadge(status: item.status)
            }
            .width(min: 100, ideal: 150)
        }
        .tableStyle(.inset)
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
        .modifier(SearchIfLong(enabled: model.items.count > 20, text: $search))
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

private struct SearchIfLong: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: "Filter files")
        } else {
            content
        }
    }
}
