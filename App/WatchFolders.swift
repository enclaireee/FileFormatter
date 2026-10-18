import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WatchRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var folderPath: String
    var presetID: String
    var isEnabled: Bool = true
    var lastEvent: Date?
}

actor WatchService {
    private var sources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var rules: [UUID: WatchRule] = [:]
    private var seen: Set<String> = []
    private var handler: (@Sendable (WatchRule, URL) async -> Void)?

    func setHandler(_ handler: @escaping @Sendable (WatchRule, URL) async -> Void) {
        self.handler = handler
    }

    func start(_ rule: WatchRule) {
        guard rule.isEnabled else { return }
        stop(rule.id)
        rules[rule.id] = rule

        let descriptor = open(rule.folderPath, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handle(ruleID: rule.id) }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources[rule.id] = source
        source.resume()
    }

    func startAll(_ rules: [WatchRule]) {
        for rule in rules { start(rule) }
    }

    func stop(_ id: UUID) {
        sources[id]?.cancel()
        sources[id] = nil
        rules[id] = nil
    }

    func stopAll() {
        for id in sources.keys { stop(id) }
    }

    func scanExisting(_ rule: WatchRule) async -> [URL] {
        await files(in: rule, since: .distantPast)
    }

    private func handle(ruleID: UUID) async {
        guard let rule = rules[ruleID] else { return }
        try? await Task.sleep(for: .milliseconds(900))
        let candidates = await files(in: rule, since: rule.lastEvent ?? Date().addingTimeInterval(-30))
        for url in candidates {
            let key = "\(url.path):\(fileStamp(url))"
            if seen.contains(key) { continue }
            if await isStable(url) {
                seen.insert(key)
                await handler?(rule, url)
            }
        }
    }

    private func files(in rule: WatchRule, since cutoff: Date) async -> [URL] {
        await Task.detached(priority: .utility) {
            Self.filesSynchronously(folderPath: rule.folderPath, since: cutoff)
        }.value
    }

    private nonisolated static func filesSynchronously(folderPath: String, since cutoff: Date) -> [URL] {
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            ), values.isRegularFile == true else { continue }
            if let modified = values.contentModificationDate, modified >= cutoff {
                result.append(url)
            }
        }
        return result
    }

    private func isStable(_ url: URL) async -> Bool {
        let first = fileStamp(url)
        try? await Task.sleep(for: .milliseconds(700))
        return first == fileStamp(url)
    }

    private func fileStamp(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}

struct WatchFoldersView: View {
    @Bindable var model: AppModel
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.watchRules.isEmpty {
                ContentUnavailableView(
                    "No watched folders",
                    systemImage: "folder.badge.gearshape",
                    description: Text("Add a folder and choose a preset. New files are converted automatically while FileFormatter is open.")
                )
            } else {
                List {
                    ForEach($model.watchRules) { $rule in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(rule.name, isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { value in
                                        rule.isEnabled = value
                                        model.updateWatch(rule)
                                    }
                                ))
                                Spacer()
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([
                                        URL(fileURLWithPath: rule.folderPath)
                                    ])
                                }
                                .controlSize(.small)
                                Button(role: .destructive) {
                                    model.removeWatch(rule)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(rule.folderPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack {
                                Text("Preset")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: Binding(
                                    get: { rule.presetID },
                                    set: { value in
                                        rule.presetID = value
                                        model.updateWatch(rule)
                                    }
                                )) {
                                    ForEach(Preset.builtIn) { preset in
                                        Text(preset.name).tag(preset.id)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let folder = urls.first {
                model.addWatch(folder: folder, presetID: "web-images")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Watch Folders")
                    .font(.headline)
                Text("Convert new files automatically while the app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Folder…") {
                showImporter = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
