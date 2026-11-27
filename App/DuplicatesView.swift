import AppKit
import FileFormatterCore
import SwiftUI
import UniformTypeIdentifiers

struct DuplicatesView: View {
    enum KeepStrategy: String, CaseIterable, Identifiable {
        case first
        case newest
        case oldest
        case shortestPath

        var id: Self { self }

        var title: String {
            switch self {
            case .first: "Keep first"
            case .newest: "Keep newest"
            case .oldest: "Keep oldest"
            case .shortestPath: "Keep shortest path"
            }
        }
    }

    @State private var groups: [DuplicateSet] = []
    @State private var scanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var pendingGroup: DuplicateSet?
    @State private var scannedFolder: URL?
    @State private var status: Status?
    @State private var keepStrategy: KeepStrategy = .first
    @State private var customKeep: [String: URL] = [:]
    @State private var expandedGroups: Set<String> = []
    @State private var modifiedDates: [URL: Date] = [:]
    @State private var isDropTargeted = false

    private let service = DuplicateService()

    private struct Status: Identifiable {
        let id = UUID()
        let text: String
        let tone: Theme.Tone
    }

    private var reclaimable: UInt64 {
        groups.reduce(0) { $0 + $1.wastedBytes }
    }

    private var subtitle: String {
        if scanning {
            return scannedFolder.map { "Reading and hashing files in \($0.lastPathComponent)…" }
                ?? "Reading and hashing files…"
        }
        if let folder = scannedFolder {
            guard !groups.isEmpty else { return "No duplicates in \(folder.lastPathComponent)." }
            return "\(groups.count) group\(groups.count == 1 ? "" : "s") · \(ByteCount.string(reclaimable)) reclaimable in \(folder.lastPathComponent)"
        }
        return "Find byte-identical files in a folder. Nothing is deleted without asking."
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Duplicates", subtitle: subtitle) {
                HStack(spacing: Theme.Space.sm) {
                    if !groups.isEmpty, !scanning {
                        Picker("Rule", selection: $keepStrategy) {
                            ForEach(KeepStrategy.allCases) { rule in
                                Text(rule.title).tag(rule)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 155)
                        .onChange(of: keepStrategy) { _, _ in
                            customKeep.removeAll()
                        }
                    }

                    if scanning {
                        ProgressView()
                            .controlSize(.small)
                        Button("Cancel") {
                            scanTask?.cancel()
                        }
                    }

                    if scannedFolder != nil, !scanning {
                        Button("Rescan") {
                            if let folder = scannedFolder {
                                startScan(folder)
                            }
                        }
                    }

                    Button(scannedFolder == nil ? "Choose Folder…" : "Choose Another…") {
                        showImporter = true
                    }
                    .disabled(scanning)
                }
            }

            if let status {
                statusBanner(status)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(Theme.Space.md)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !scanning, let folder = urls.first(where: { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }) else { return false }
            startScan(folder)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                startScan(folder)
            case .failure(let error):
                status = Status(text: error.localizedDescription, tone: .danger)
            }
        }
        .confirmationDialog(
            "Move duplicate copies to the Trash?",
            isPresented: Binding(
                get: { pendingGroup != nil },
                set: { if !$0 { pendingGroup = nil } }
            )
        ) {
            Button("Move \(pendingGroup.map { $0.paths.count - 1 } ?? 0) to Trash", role: .destructive) {
                guard let group = pendingGroup else { return }
                pendingGroup = nil
                Task { await trashExtras(in: group) }
            }
            Button("Cancel", role: .cancel) { pendingGroup = nil }
        } message: {
            if let group = pendingGroup, let kept = keptURL(for: group) {
                Text("\"\(kept.lastPathComponent)\" in \(kept.deletingLastPathComponent().lastPathComponent) is kept. \(group.paths.count - 1) other copies move to the Trash.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if scanning {
            VStack(spacing: Theme.Space.md) {
                ProgressView()
                Text("Reading and hashing files")
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
                if let folder = scannedFolder {
                    Text(folder.path)
                        .font(Theme.Text.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scannedFolder == nil {
            EmptyStatePanel(
                systemImage: "square.on.square",
                title: "Find duplicate files",
                message: "Choose or drop a folder to compare files by content, not name. Choose which copy of each set to keep."
            ) {
                Button("Choose Folder…") {
                    showImporter = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else if groups.isEmpty {
            EmptyStatePanel(
                systemImage: "checkmark.seal",
                title: "No duplicates found",
                message: "Everything in \(scannedFolder?.lastPathComponent ?? "this folder") is unique."
            ) {
                HStack(spacing: Theme.Space.sm) {
                    Button("Choose Another…") {
                        showImporter = true
                    }
                    Button("Scan Again") {
                        if let folder = scannedFolder {
                            startScan(folder)
                        }
                    }
                }
            }
        } else {
            List(groups) { group in
                groupRow(group)
            }
            .listStyle(.inset)
        }
    }

    private func statusBanner(_ status: Status) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: status.tone == .danger ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.color(for: status.tone))
                .accessibilityHidden(true)
            Text(status.text)
                .font(Theme.Text.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            Button {
                self.status = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        .background(Theme.Palette.fill(for: status.tone), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.sm)
    }

    private func keptURL(for group: DuplicateSet) -> URL? {
        if let chosen = customKeep[group.id],
           group.paths.contains(where: { $0.standardizedFileURL == chosen.standardizedFileURL }) {
            return chosen
        }
        switch keepStrategy {
        case .first:
            return group.paths.first
        case .newest:
            return group.paths.max {
                (modifiedDates[$0] ?? .distantPast) < (modifiedDates[$1] ?? .distantPast)
            }
        case .oldest:
            return group.paths.min {
                (modifiedDates[$0] ?? .distantFuture) < (modifiedDates[$1] ?? .distantFuture)
            }
        case .shortestPath:
            return group.paths.min { $0.path.count < $1.path.count }
        }
    }

    private func groupRow(_ group: DuplicateSet) -> some View {
        let kept = keptURL(for: group)
        let isExpanded = expandedGroups.contains(group.id)
        let visiblePaths = isExpanded ? group.paths : Array(group.paths.prefix(4))

        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                IconTile(systemImage: "square.on.square", tone: .warning, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.paths.count) identical copies")
                        .font(.headline)
                    Text("\(ByteCount.string(group.byteSize)) each · \(ByteCount.string(group.wastedBytes)) reclaimable")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.sm)
                Button("Move \(group.paths.count - 1) to Trash") {
                    pendingGroup = group
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(visiblePaths, id: \.self) { path in
                    let isKept = path.standardizedFileURL == kept?.standardizedFileURL
                    HStack(spacing: 6) {
                        if isKept {
                            Badge(text: "Keep", systemImage: "checkmark", tone: .accent)
                                .frame(width: 62, alignment: .leading)
                        } else {
                            Button("Keep") {
                                customKeep[group.id] = path
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .leading)
                            .help("Keep this copy instead")
                        }

                        Text(path.path)
                            .font(Theme.Text.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path.path)

                        Spacer(minLength: Theme.Space.sm)

                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([path])
                        }
                        .buttonStyle(.link)
                        .font(Theme.Text.caption)
                    }
                }
                if group.paths.count > 4 {
                    Button(isExpanded ? "Show fewer" : "Show all \(group.paths.count) copies…") {
                        if isExpanded {
                            expandedGroups.remove(group.id)
                        } else {
                            expandedGroups.insert(group.id)
                        }
                    }
                    .buttonStyle(.link)
                    .font(Theme.Text.caption)
                    .padding(.leading, 68)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func startScan(_ folder: URL) {
        scanTask?.cancel()
        scanTask = Task { await scan(folder) }
    }

    private func scan(_ folder: URL) async {
        scanning = true
        status = nil
        groups = []
        customKeep = [:]
        expandedGroups = []
        scannedFolder = folder
        defer { scanning = false }

        do {
            let found = try await service.scan(folder: folder)
            let dates = await Task.detached(priority: .utility) {
                var map: [URL: Date] = [:]
                for group in found {
                    for url in group.paths {
                        if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                            map[url] = mtime
                        }
                    }
                }
                return map
            }.value
            guard !Task.isCancelled else { return }
            modifiedDates = dates
            groups = found
            if found.isEmpty {
                status = Status(text: "No byte-identical files in \(folder.lastPathComponent).", tone: .info)
            }
        } catch is CancellationError {
            scannedFolder = nil
            status = Status(text: "Duplicate scan cancelled.", tone: .info)
        } catch {
            scannedFolder = nil
            status = Status(text: error.localizedDescription, tone: .danger)
        }
    }

    private func trashExtras(in group: DuplicateSet) async {
        guard let keep = keptURL(for: group) else { return }
        let result = await service.trashExtras(in: group, keeping: keep)
        groups.removeAll { $0.id == group.id }
        customKeep[group.id] = nil
        expandedGroups.remove(group.id)
        if result.trashed > 0 {
            let summary = RunSummary(
                target: "Duplicates Cleanup",
                outputs: [],
                converted: result.trashed,
                skipped: 1,
                failed: result.failed,
                inputBytes: group.byteSize * UInt64(group.paths.count),
                outputBytes: group.byteSize
            )
            try? await RunJournal.shared.save(summary)
        }
        status = Status(
            text: result.failed == 0
                ? "\(result.trashed) file\(result.trashed == 1 ? "" : "s") moved to the Trash."
                : "\(result.trashed) moved; \(result.failed) could not be moved.",
            tone: result.failed == 0 ? .success : .warning
        )
    }
}
