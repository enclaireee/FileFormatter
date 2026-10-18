import FileFormatterCore
import SwiftUI

struct QueueView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            summaryStrip
            if !model.warnings.isEmpty {
                warningBanner
            }
            Divider()
            table
        }
    }

    private var summaryStrip: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.items.count) file\(model.items.count == 1 ? "" : "s")")
                    .font(.headline)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.isRunning && !model.items.isEmpty {
                    QuickActionRow(urls: model.items.map(\.sourceURL), limit: 5, controlSize: .small) { action in
                        Task {
                            guard let summary = await model.quickRun(urls: model.items.map(\.sourceURL), action: action) else { return }
                            model.lastSummary = summary
                            model.showCompletion = true
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
            if model.isPlanning {
                ProgressView()
                    .controlSize(.small)
                Text("Planning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(model.warnings.joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }

    private var detailLine: String {
        let bytes = ByteCount.string(model.inputBytes)
        let fidelities = model.fidelityCounts
            .map { "\($0.1) \($0.0.label.lowercased())" }
            .joined(separator: " · ")
        return fidelities.isEmpty ? "\(bytes) total" : "\(bytes) total · \(fidelities)"
    }

    private var table: some View {
        Table(model.items, selection: $model.selectedID) {
            TableColumn("Source") { item in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: item.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .lineLimit(1)
                        Text(subtitle(for: item))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .help(item.note ?? item.sourceURL.path)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Output") { item in
                Text(item.outputName)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(item.fidelity == .unsupported ? .secondary : .primary)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Fidelity") { item in
                FidelityBadge(level: item.fidelity)
            }
            .width(104)

            TableColumn("Size") { item in
                Text(ByteCount.string(item.byteSize))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(78)

            TableColumn("Status") { item in
                StatusBadge(status: item.status)
            }
            .width(118)
        }
        .tableStyle(.inset)
        .onDeleteCommand {
            model.removeSelected()
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
