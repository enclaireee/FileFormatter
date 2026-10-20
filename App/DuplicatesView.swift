import AppKit
import FileFormatterCore
import SwiftUI
import UniformTypeIdentifiers

struct DuplicatesView: View {
    @State private var groups: [DuplicateSet] = []
    @State private var scanning = false
    @State private var showImporter = false
    @State private var pendingGroup: DuplicateSet?
    @State private var scannedFolder: URL?
    @State private var status: Status?

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
                    if scanning {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if scannedFolder != nil, !scanning {
                        Button("Rescan") {
                            if let folder = scannedFolder {
                                Task { await scan(folder) }
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
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                Task { await scan(folder) }
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
            if let group = pendingGroup {
                Text("The first copy is kept. \(group.paths.count - 1) other copies move to the Trash. You can restore them from the Trash.")
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
                message: "Choose a folder to compare files by content, not name. The first copy of each set is always kept."
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
                            Task { await scan(folder) }
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

    private func groupRow(_ group: DuplicateSet) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
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
                ForEach(Array(group.paths.prefix(4)), id: \.self) { path in
                    HStack(spacing: 6) {
                        if path.standardizedFileURL == group.paths.first?.standardizedFileURL {
                            Badge(text: "Keep", systemImage: "checkmark", tone: .accent)
                                .frame(width: 58, alignment: .leading)
                        } else {
                            Image(systemName: "doc")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 58, alignment: .leading)
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
                    Text("and \(group.paths.count - 4) more…")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 64)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func scan(_ folder: URL) async {
        scanning = true
        status = nil
        groups = []
        scannedFolder = folder
        defer { scanning = false }

        do {
            let found = try await service.scan(folder: folder)
            groups = found
            if found.isEmpty {
                status = Status(text: "No byte-identical files in \(folder.lastPathComponent).", tone: .info)
            }
        } catch {
            scannedFolder = nil
            status = Status(text: error.localizedDescription, tone: .danger)
        }
    }

    private func trashExtras(in group: DuplicateSet) async {
        guard let keep = group.paths.first else { return }
        let result = await service.trashExtras(in: group, keeping: keep)
        groups.removeAll { $0.id == group.id }
        status = Status(
            text: result.failed == 0
                ? "\(result.trashed) file\(result.trashed == 1 ? "" : "s") moved to the Trash."
                : "\(result.trashed) moved; \(result.failed) could not be moved.",
            tone: result.failed == 0 ? .success : .warning
        )
    }
}
