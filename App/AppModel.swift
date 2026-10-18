import AppKit
import FileFormatterCore
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    struct AlertPayload: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var items: [ConversionItem] = []
    var warnings: [String] = []
    var imageTarget: ConversionTarget = .jpeg
    var dataTarget: ConversionTarget = .json
    var documentTarget: ConversionTarget = .markdown
    var audioTarget: ConversionTarget = .mp3
    var videoTarget: ConversionTarget = .mp4
    var quality: Double = 0.85
    var suffix: String = "-converted"
    var preserveMetadata = true
    var ocrPDF = false

    var isPlanning = false
    var isRunning = false
    var selectedID: UUID?
    var showImporter = false
    var showCompletion = false
    var lastSummary: RunSummary?
    var alert: AlertPayload?
    var watchRules: [WatchRule] = []
    var completedCount = 0
    var totalToConvert = 0

    private let service = ConversionService()
    private let journal = RunJournal.shared
    private let watchService = WatchService()
    private var replanTask: Task<Void, Never>?
    private var watchStarted = false

    init() {
        watchRules = Self.loadWatchRules()
        Task { await startWatching() }
    }

    var isEmpty: Bool { items.isEmpty }

    var activePreset: Preset? {
        Preset.builtIn.first { preset in
            preset.imageTarget == imageTarget
                && preset.dataTarget == dataTarget
                && preset.documentTarget == documentTarget
                && preset.audioTarget == audioTarget
                && preset.videoTarget == videoTarget
                && preset.suffix == suffix
                && abs(preset.quality - quality) < 0.001
        }
    }

    func apply(_ preset: Preset) {
        imageTarget = preset.imageTarget
        dataTarget = preset.dataTarget
        documentTarget = preset.documentTarget
        audioTarget = preset.audioTarget
        videoTarget = preset.videoTarget
        quality = preset.quality
        suffix = preset.suffix
        scheduleReplan()
    }

    func target(for kind: FileKind) -> ConversionTarget? {
        switch kind {
        case .image: imageTarget
        case .data: dataTarget
        case .document: documentTarget
        case .audio: audioTarget
        case .video: videoTarget
        default: nil
        }
    }

    func hasKind(_ kind: FileKind) -> Bool {
        items.contains { $0.kind == kind }
    }
    var runnableCount: Int { items.filter { $0.status == .pending }.count }
    var inputBytes: UInt64 {
        var seen = Set<String>()
        var total: UInt64 = 0
        for item in items where seen.insert(item.sourceURL.path).inserted {
            total += item.byteSize
        }
        return total
    }

    var fidelityCounts: [(FidelityLevel, Int)] {
        FidelityLevel.allCases.compactMap { level in
            let count = items.filter { $0.fidelity == level }.count
            return count > 0 ? (level, count) : nil
        }
    }

    func addFiles(_ urls: [URL]) {
        Task {
            let expanded = await Self.expand(urls)
            guard !expanded.isEmpty else {
                present(
                    "No supported files",
                    "Drop images or tabular data (CSV, TSV, JSON, YAML, TOML). PDF, audio, and video arrive in later milestones."
                )
                return
            }
            let existing = Set(items.map { $0.sourceURL.standardizedFileURL.path })
            let new = expanded.filter { !existing.contains($0.standardizedFileURL.path) }
            guard !new.isEmpty else { return }
            await plan(urls: items.map(\.sourceURL) + new)
        }
    }

    func scheduleReplan() {
        replanTask?.cancel()
        replanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await plan(urls: self.items.map(\.sourceURL))
        }
    }

    func run() async {
        guard !isRunning else { return }
        let pending = items.filter { $0.status == .pending }
        guard !pending.isEmpty else { return }

        isRunning = true
        totalToConvert = pending.count
        completedCount = 0
        defer { isRunning = false }

        var outputs: [URL] = []
        var converted = 0
        var skipped = items.filter { item in
            if case .skipped = item.status { true } else { false }
        }.count
        var failed = 0
        var outputBytes: UInt64 = 0

        for index in items.indices {
            guard items[index].status == .pending else { continue }
            guard let itemTarget = items[index].ocrPDF
                    ? ConversionTarget.searchablePDF
                    : target(for: items[index].kind) else {
                items[index].status = .skipped("No target for \(items[index].kind.label) yet")
                continue
            }
            items[index].status = .converting
            do {
                let options = ConversionOptions(
                    target: itemTarget,
                    quality: quality,
                    suffix: suffix,
                    preserveMetadata: preserveMetadata
                )
                let result = try await service.convert(items[index], options: options)
                items[index].status = .completed
                items[index].outputURL = result.url
                outputs.append(result.url)
                outputBytes += result.outputBytes
                converted += 1
            } catch {
                items[index].status = .failed(error.localizedDescription)
                failed += 1
            }
            completedCount += 1
        }

        // Items skipped before the run (unsupported targets) still belong in the summary.
        skipped = items.filter { item in
            if case .skipped = item.status { true } else { false }
        }.count

        let usedTargets = Set(items.compactMap { target(for: $0.kind)?.displayName })
        let summary = RunSummary(
            target: usedTargets.count == 1 ? (usedTargets.first ?? "Mixed") : "Mixed",
            outputs: outputs,
            converted: converted,
            skipped: skipped,
            failed: failed,
            inputBytes: inputBytes,
            outputBytes: outputBytes
        )
        try? await journal.save(summary)
        NotificationService.shared.notify(summary)
        lastSummary = summary
        showCompletion = true
    }

    func undoLastRun() async {
        guard var summary = lastSummary, !summary.undone else { return }
        let result = await service.undo(summary)
        try? await journal.markUndone(id: summary.id)
        summary.undone = true
        lastSummary = summary

        for index in items.indices {
            guard case .completed = items[index].status else { continue }
            items[index].status = .pending
            items[index].outputURL = nil
        }

        showCompletion = false
        present(
            "Run undone",
            result.failed == 0
                ? "\(result.removed) generated file(s) moved to the Trash."
                : "\(result.removed) file(s) moved to the Trash; \(result.failed) could not be removed."
        )
    }

    func revealLastOutputs() {
        guard let outputs = lastSummary?.outputs, !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    func reveal(_ item: ConversionItem) {
        if let outputURL = item.outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([item.sourceURL])
        }
    }

    func removeSelected() {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        items.remove(at: index)
        self.selectedID = nil
    }

    func addWatch(folder: URL, presetID: String) {
        let rule = WatchRule(
            name: folder.lastPathComponent,
            folderPath: folder.standardizedFileURL.path,
            presetID: presetID
        )
        watchRules.append(rule)
        saveWatchRules()
        Task { await watchService.start(rule) }
    }

    func updateWatch(_ rule: WatchRule) {
        guard let index = watchRules.firstIndex(where: { $0.id == rule.id }) else { return }
        watchRules[index] = rule
        saveWatchRules()
        Task {
            if rule.isEnabled {
                await watchService.start(rule)
            } else {
                await watchService.stop(rule.id)
            }
        }
    }

    func removeWatch(_ rule: WatchRule) {
        watchRules.removeAll { $0.id == rule.id }
        saveWatchRules()
        Task { await watchService.stop(rule.id) }
    }

    private func startWatching() async {
        guard !watchStarted else { return }
        watchStarted = true
        await watchService.setHandler { [weak self] rule, url in
            await self?.handleWatchedFile(rule: rule, url: url)
        }
        await watchService.startAll(watchRules)
    }

    private func handleWatchedFile(rule: WatchRule, url: URL) async {
        guard let preset = Preset.builtIn.first(where: { $0.id == rule.presetID }) else { return }
        do {
            let plan = try await service.makePlan(
                urls: [url],
                targets: TargetRecipe(
                    image: preset.imageTarget,
                    data: preset.dataTarget,
                    document: preset.documentTarget,
                    audio: preset.audioTarget,
                    video: preset.videoTarget
                ),
                suffix: preset.suffix
            )
            let pending = plan.items.filter { $0.status == .pending }
            guard !pending.isEmpty else { return }

            var outputs: [URL] = []
            var inputBytes: UInt64 = 0
            var outputBytes: UInt64 = 0
            var failures = 0
            for item in pending {
                guard let itemTarget = targets(for: item).target(for: item.kind) else { continue }
                inputBytes += item.byteSize
                do {
                    let result = try await service.convert(
                        item,
                        options: ConversionOptions(
                            target: itemTarget,
                            quality: preset.quality,
                            suffix: preset.suffix,
                            preserveMetadata: true
                        )
                    )
                    outputs.append(result.url)
                    outputBytes += result.outputBytes
                } catch {
                    failures += 1
                }
            }
            guard !outputs.isEmpty || failures > 0 else { return }
            let summary = RunSummary(
                target: preset.name,
                outputs: outputs,
                converted: outputs.count,
                skipped: plan.items.filter {
                    if case .skipped = $0.status { true } else { false }
                }.count,
                failed: failures,
                inputBytes: inputBytes,
                outputBytes: outputBytes
            )
            try? await journal.save(summary)
            NotificationService.shared.notify(summary)
        } catch {
            // Watched conversions are silent by design; failures remain visible in History.
        }
    }

    private func targets(for item: ConversionItem) -> TargetRecipe {
        TargetRecipe(image: imageTarget, data: dataTarget, document: documentTarget)
    }

    private static func loadWatchRules() -> [WatchRule] {
        guard let data = try? Data(contentsOf: watchRulesURL) else { return [] }
        return (try? JSONDecoder().decode([WatchRule].self, from: data)) ?? []
    }

    private func saveWatchRules() {
        guard let data = try? JSONEncoder().encode(watchRules) else { return }
        try? data.write(to: Self.watchRulesURL, options: .atomic)
    }

    private static var watchRulesURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("FileFormatter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("watches.json")
    }

    func clearQueue() {
        guard !isRunning else { return }
        items.removeAll()
        warnings.removeAll()
        selectedID = nil
        lastSummary = nil
    }

    func present(_ title: String, _ message: String) {
        alert = AlertPayload(title: title, message: message)
    }

    func present(error: Error) {
        present("Something went wrong", error.localizedDescription)
    }

    private func plan(urls: [URL]) async {
        guard !urls.isEmpty else {
            items.removeAll()
            return
        }
        isPlanning = true
        defer { isPlanning = false }

        do {
            let result = try await service.makePlan(
                urls: urls,
                targets: TargetRecipe(
                    image: imageTarget,
                    data: dataTarget,
                    document: documentTarget,
                    audio: audioTarget,
                    video: videoTarget
                ),
                suffix: suffix,
                ocrPDF: ocrPDF
            )
            items = result.items
            warnings = result.warnings
        } catch {
            present(error: error)
        }
    }


    private nonisolated static func expand(_ urls: [URL]) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            expandSynchronously(urls)
        }.value
    }

    private nonisolated static func expandSynchronously(_ urls: [URL]) -> [URL] {
        let supported: Set<String> = [
            "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "heif",
            "avif", "webp", "bmp", "ico", "psd", "dng", "cr2", "cr3",
            "nef", "arw", "raf", "orf", "rw2", "pdf"
        ]
        var result: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let file as URL in enumerator {
                    if supported.contains(file.pathExtension.lowercased()) {
                        result.append(file)
                    }
                }
            } else if supported.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }
}
