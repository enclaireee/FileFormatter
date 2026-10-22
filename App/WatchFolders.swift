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
    // ponytail: last handled stamp per path, so edits replace an entry instead of adding one. Grows only with
    // distinct files ever dropped in; prune missing paths if a watch folder ever sees millions.
    private var seen: [String: String] = [:]
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
            let stamp = fileStamp(url)
            if seen[url.path] == stamp { continue }
            if await isStable(url) {
                seen[url.path] = stamp
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

    private func ruleRow(_ rule: Binding<WatchRule>) -> some View {
        let value = rule.wrappedValue
        let exists = FileManager.default.fileExists(atPath: value.folderPath)

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
