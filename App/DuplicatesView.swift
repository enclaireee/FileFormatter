import AppKit
import FileFormatterCore
import SwiftUI
import UniformTypeIdentifiers

struct DuplicatesView: View {
    @State private var groups: [DuplicateSet] = []
    @State private var scanning = false
    @State private var showImporter = false
    @State private var pendingGroup: DuplicateSet?
    @State private var message: String?

    private let service = DuplicateService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
                message = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Move duplicate copies to the Trash?",
            isPresented: Binding(
                get: { pendingGroup != nil },
                set: { if !$0 { pendingGroup = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let group = pendingGroup else { return }
                pendingGroup = nil
                Task { await trashExtras(in: group) }
            }
            Button("Cancel", role: .cancel) { pendingGroup = nil }
        } message: {
            if let group = pendingGroup {
                Text("The first copy is kept. \(group.paths.count - 1) other copies move to the Trash.")
            }
        }
        .alert("Duplicates", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Finder")
                    .font(.headline)
                Text(groups.isEmpty
                     ? "Find byte-identical files in a folder."
                     : "\(groups.count) groups · \(ByteCount.string(groups.reduce(0) { $0 + $1.wastedBytes })) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if scanning {
                ProgressView()
                    .controlSize(.small)
                Text("Hashing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Choose Folder…") {
                showImporter = true
            }
            .disabled(scanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                scanning ? "Scanning folder" : "No duplicates found",
                systemImage: "square.on.square",
                description: Text(scanning
                    ? "Reading and hashing files. Large folders can take a moment."
                    : "Choose a folder to compare files by content, not name.")
            )
        } else {
            List(groups) { group in
                groupRow(group)
            }
            .listStyle(.inset)
        }
    }

    private func groupRow(_ group: DuplicateSet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(group.paths.count) identical copies")
                    .font(.headline)
                Text(ByteCount.string(group.byteSize))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ByteCount.string(group.wastedBytes)) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Move Extras to Trash") {
                    pendingGroup = group
                }
                .controlSize(.small)
            }

            ForEach(Array(group.paths.prefix(4)), id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .foregroundStyle(.tertiary)
                    Text(path.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([path])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if group.paths.count > 4 {
                Text("and \(group.paths.count - 4) more…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private func scan(_ folder: URL) async {
        scanning = true
        defer { scanning = false }
        do {
            groups = try await service.scan(folder: folder)
            if groups.isEmpty {
                message = "No byte-identical files were found in \(folder.lastPathComponent)."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func trashExtras(in group: DuplicateSet) async {
        guard let keep = group.paths.first else { return }
        let result = await service.trashExtras(in: group, keeping: keep)
        groups.removeAll { $0.id == group.id }
        message = result.failed == 0
            ? "\(result.trashed) file(s) moved to the Trash."
            : "\(result.trashed) moved; \(result.failed) could not be moved."
    }
}
