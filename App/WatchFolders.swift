import AppKit
import CoreServices
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
    var folderBookmark: Data? = nil

    func resolvedFolderURL() -> (url: URL, scoped: Bool) {
        if let folderBookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: folderBookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let scoped = resolved.startAccessingSecurityScopedResource()
                return (resolved, scoped)
            }
        }
        return (URL(fileURLWithPath: folderPath, isDirectory: true), false)
    }
}

private final class FSEventBox: @unchecked Sendable {
    weak var service: WatchService?
    let ruleID: UUID

    init(service: WatchService, ruleID: UUID) {
        self.service = service
        self.ruleID = ruleID
    }
}

actor WatchService {
    private var streams: [UUID: FSEventStreamRef] = [:]
    private var scopedFolders: [UUID: URL] = [:]
    private var rules: [UUID: WatchRule] = [:]
    private var seen: [String: String] = [:]
    /// Outputs written by watched runs themselves, preventing self-triggering conversion loops.
    private var ownOutputs: [String: String] = [:]
    private var pendingPaths: [UUID: Set<String>] = [:]
    private var drainTasks: [UUID: Task<Void, Never>] = [:]
    private var handler: (@Sendable (WatchRule, URL) async -> Void)?

    func setHandler(_ handler: @escaping @Sendable (WatchRule, URL) async -> Void) {
        self.handler = handler
    }

    func recordGeneratedOutputs(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            let stamp = fileStamp(url)
            ownOutputs[path] = stamp
            seen[path] = stamp
        }
        if ownOutputs.count > 4_096 {
            ownOutputs.removeAll(keepingCapacity: true)
        }
    }

    func start(_ rule: WatchRule) {
        guard rule.isEnabled else { return }
        stop(rule.id)
        var updatedRule = rule
        let (folderURL, scoped) = rule.resolvedFolderURL()
        if scoped {
            scopedFolders[rule.id] = folderURL
        }
        let path = folderURL.standardizedFileURL.path
        updatedRule.folderPath = path
        rules[rule.id] = updatedRule

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        let box = FSEventBox(service: self, ruleID: rule.id)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagIgnoreSelf
        )

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
            guard let clientInfo else { return }
            let box = Unmanaged<FSEventBox>.fromOpaque(clientInfo).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
            var candidates: [String] = []
            for i in 0..<min(paths.count, flagsBuffer.count) {
                let flag = flagsBuffer[i]
                let removed = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0
                let isDirectory = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0
                if removed || isDirectory { continue }
                let candidate = paths[i]
                let name = (candidate as NSString).lastPathComponent
                if name.hasPrefix(".") { continue }
                candidates.append(candidate)
            }
            guard !candidates.isEmpty, let service = box.service else { return }
            let ruleID = box.ruleID
            Task { await service.enqueue(ruleID: ruleID, paths: candidates) }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.7,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        if FSEventStreamStart(stream) {
            streams[rule.id] = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func startAll(_ rules: [WatchRule]) {
        for rule in rules { start(rule) }
    }

    func stop(_ id: UUID) {
        drainTasks[id]?.cancel()
        drainTasks[id] = nil
        pendingPaths[id] = nil
        if let stream = streams.removeValue(forKey: id) {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if let scoped = scopedFolders.removeValue(forKey: id) {
            scoped.stopAccessingSecurityScopedResource()
        }
        rules[id] = nil
    }

    func stopAll() {
        for id in Array(streams.keys) { stop(id) }
    }

    func scanExisting(_ rule: WatchRule) async -> [URL] {
        await Task.detached(priority: .utility) {
            Self.filesSynchronously(folderPath: rule.folderPath, since: .distantPast)
        }.value
    }

    fileprivate func enqueue(ruleID: UUID, paths: [String]) {
        guard rules[ruleID] != nil else { return }
        pendingPaths[ruleID, default: []].formUnion(paths)
        guard drainTasks[ruleID] == nil else { return }
        drainTasks[ruleID] = Task { [weak self] in
            await self?.drain(ruleID: ruleID)
        }
    }

    private func drain(ruleID: UUID) async {
        defer { drainTasks[ruleID] = nil }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let rule = rules[ruleID] else { return }
            guard let batch = pendingPaths.removeValue(forKey: ruleID), !batch.isEmpty else { break }

            let presetSuffix = Preset.builtIn.first(where: { $0.id == rule.presetID })?.suffix ?? ""
            for rawPath in batch.sorted() {
                guard !Task.isCancelled, rules[ruleID] != nil else { return }
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                let path = url.path
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }

                let stem = url.deletingPathExtension().lastPathComponent
                if stem.hasSuffix("-converted")
                    || (!presetSuffix.isEmpty && stem.hasSuffix(presetSuffix)) {
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }

                let stamp = fileStamp(url)
                if ownOutputs[path] == stamp || seen[path] == stamp { continue }
                if await isStable(url) {
                    let finalStamp = fileStamp(url)
                    if ownOutputs[path] == finalStamp || seen[path] == finalStamp { continue }
                    seen[path] = finalStamp
                    await handler?(rule, url)
                }
            }
            if seen.count > 8_192 {
                seen = seen.filter { FileManager.default.fileExists(atPath: $0.key) }
            }
        }
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
        try? await Task.sleep(for: .milliseconds(550))
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: url.path) else { return false }
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
    @State private var missingIDs: Set<UUID> = []
    @State private var isDropTargeted = false

    private var activeCount: Int {
        model.watchRules.filter(\.isEnabled).count
    }

    private var subtitle: String {
        guard !model.watchRules.isEmpty else {
            return "Convert new files automatically while FileFormatter is open."
        }
        return "\(model.watchRules.count) rule\(model.watchRules.count == 1 ? "" : "s") · \(activeCount) active · New files convert on arrival."
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Watch Folders", subtitle: subtitle) {
                Button("Add Folder…") {
                    showImporter = true
                }
            }

            if model.watchRules.isEmpty {
                EmptyStatePanel(
                    systemImage: "folder.badge.gearshape",
                    title: "No watched folders",
                    message: "Choose a folder and a preset. New files are converted automatically while FileFormatter is open."
                ) {
                    Button("Choose Folder…") {
                        showImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach($model.watchRules) { $rule in
                        ruleRow($rule)
                            .padding(.vertical, 5)
                    }
                }
                .listStyle(.inset)
            }
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
            var added = false
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    model.addWatch(folder: url, presetID: "web-images")
                    added = true
                }
            }
            return added
        } isTargeted: { isDropTargeted = $0 }
        .task(id: model.watchRules) {
            await refreshExistence()
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

    private func refreshExistence() async {
        let snapshot = model.watchRules
        let missing = await Task.detached(priority: .utility) {
            Set(snapshot.filter { !FileManager.default.fileExists(atPath: $0.folderPath) }.map(\.id))
        }.value
        missingIDs = missing
    }

    private func ruleRow(_ rule: Binding<WatchRule>) -> some View {
        let value = rule.wrappedValue
        let exists = !missingIDs.contains(value.id)

        return HStack(alignment: .top, spacing: Theme.Space.md) {
            IconTile(
                systemImage: "folder",
                tone: value.isEnabled ? .accent : .neutral,
                size: 34
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Theme.Space.sm) {
                    Toggle("", isOn: Binding(
                        get: { rule.wrappedValue.isEnabled },
                        set: { on in update(rule) { $0.isEnabled = on } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Watch \(value.name)")

                    Text(value.name)
                        .font(.headline)
                        .lineLimit(1)

                    Badge(
                        text: value.isEnabled ? "Active" : "Paused",
                        systemImage: value.isEnabled ? "bolt.fill" : "pause.fill",
                        tone: value.isEnabled ? .success : .neutral
                    )

                    if !exists {
                        Badge(text: "Folder missing", systemImage: "exclamationmark.triangle.fill", tone: .warning)
                    }

                    Spacer(minLength: Theme.Space.sm)

                    Menu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: value.folderPath)
                            ])
                        }
                        .disabled(!exists)

                        Divider()

                        Button("Remove Watched Folder", role: .destructive) {
                            model.removeWatch(value)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More actions")
                }

                Text(value.folderPath)
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value.folderPath)

                HStack(spacing: Theme.Space.sm) {
                    Text("Preset")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { rule.wrappedValue.presetID },
                        set: { id in update(rule) { $0.presetID = id } }
                    )) {
                        ForEach(Preset.builtIn) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 240)

                    Spacer(minLength: Theme.Space.sm)

                    if let lastEvent = value.lastEvent {
                        Text("Last run \(lastEvent.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .opacity(value.isEnabled ? 1 : 0.62)
        .animation(.default, value: value.isEnabled)
    }

    private func update(_ rule: Binding<WatchRule>, _ change: (inout WatchRule) -> Void) {
        var value = rule.wrappedValue
        change(&value)
        rule.wrappedValue = value
        model.updateWatch(value)
    }
}
