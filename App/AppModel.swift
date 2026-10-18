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
    var pdfMode: PDFMode = .pages
    var removeBackground = false
    var maxPixelSize: Int?
    var imageTargetBytes: UInt64?
    var videoTargetBytes: UInt64?

    var isPlanning = false
    var isRunning = false
    var selectedID: UUID?
    var showImporter = false
    var showCompletion = false
    var showRename = false
    var lastSummary: RunSummary?
    var alert: AlertPayload?
    var watchRules: [WatchRule] = []
    var completedCount = 0
    var totalToConvert = 0

    /// Menu bar / Finder runs, tracked separately so they never touch the window queue.
    var quickItems: [ConversionItem] = []
    var quickSummary: RunSummary?
    var isQuickRunning = false

    private let service = ConversionService()
    private let journal = RunJournal.shared
    private let watchService = WatchService()
    private var replanTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var quickTask: Task<RunSummary?, Never>?
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
                    "No files found",
                    "Drop images, PDFs, audio, video, Word or PowerPoint files, or data files (CSV, JSON, YAML, TOML, XLSX)."
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

    /// The window's settings as a job.
    var windowJob: ConversionJob {
        ConversionJob(
            label: activePreset?.name ?? "Mixed",
            targets: TargetRecipe(
                image: imageTarget,
                data: dataTarget,
                document: documentTarget,
                audio: audioTarget,
                video: videoTarget
            ),
            pdfMode: pdfMode,
            suffix: suffix,
            quality: quality,
            preserveMetadata: preserveMetadata,
            maxPixelSize: maxPixelSize,
            imageTargetBytes: imageTargetBytes,
            mediaTargetBytes: videoTargetBytes,
            removeBackground: removeBackground
        )
    }

    var isBusy: Bool { isRunning || isQuickRunning }

    func startRun() {
        guard !isRunning else { return }
        runTask = Task { await run() }
    }

    func cancel() {
        runTask?.cancel()
        quickTask?.cancel()
    }

    func run() async {
        guard !isRunning else { return }
        let pendingCount = items.filter { $0.status == .pending }.count
        guard pendingCount > 0 else { return }

        isRunning = true
        totalToConvert = pendingCount
        completedCount = 0
        defer { isRunning = false }

        let job = windowJob
        let tally = await execute(items, job: job) { index, status, output in
            self.items[index].status = status
            self.items[index].outputURL = output
            if status.isTerminal { self.completedCount += 1 }
        }

        let summary = tally.summary(job: job, items: items)
        try? await journal.save(summary)
        if tally.cancelled {
            present("Conversion cancelled", "\(tally.converted) file(s) finished before you stopped. The rest are still in the queue.")
        } else {
            NotificationService.shared.notify(summary)
        }
        lastSummary = summary
        showCompletion = !tally.cancelled
    }

    /// Plans and converts files without the window: menu bar, Finder services, watch folders.
    @discardableResult
    func quickRun(urls: [URL], job: ConversionJob, showsProgress: Bool = true) async -> RunSummary? {
        if showsProgress {
            quickTask?.cancel()
            let task = Task { await performQuickRun(urls: urls, job: job, showsProgress: true) }
            quickTask = task
            return await task.value
        }
        return await performQuickRun(urls: urls, job: job, showsProgress: false)
    }

    @discardableResult
    func quickRun(urls: [URL], action: QuickAction, showsProgress: Bool = true) async -> RunSummary? {
        await quickRun(urls: urls, job: action.job, showsProgress: showsProgress)
    }

    private func performQuickRun(urls: [URL], job: ConversionJob, showsProgress: Bool) async -> RunSummary? {
        let expanded = await Self.expand(urls)
        guard !expanded.isEmpty else { return nil }
        if showsProgress {
            isQuickRunning = true
            quickSummary = nil
        }
        defer { if showsProgress { isQuickRunning = false } }

        let plan: PlanResult
        do {
            plan = try await service.makePlan(
                urls: expanded,
                targets: job.targets,
                suffix: job.suffix,
                pdfMode: job.pdfMode
            )
        } catch {
            if showsProgress { present(error: error) }
            return nil
        }

        var planned = plan.items
        if showsProgress { quickItems = planned }
        let tally = await execute(planned, job: job) { index, status, output in
            planned[index].status = status
            planned[index].outputURL = output
            if showsProgress { self.quickItems = planned }
        }
        let summary = tally.summary(job: job, items: planned)
        guard summary.converted + summary.failed > 0 else {
            if showsProgress { quickSummary = summary }
            return summary
        }
        try? await journal.save(summary)
        if !tally.cancelled { NotificationService.shared.notify(summary) }
        if showsProgress { quickSummary = summary }
        return summary
    }

    func undo(_ summary: RunSummary) async -> (removed: Int, failed: Int) {
        let result = await service.undo(summary)
        try? await journal.markUndone(id: summary.id)
        if quickSummary?.id == summary.id { quickSummary?.undone = true }
        return result
    }

    private struct RunTally {
        var outputs: [URL] = []
        var converted = 0
        var failed = 0
        var outputBytes: UInt64 = 0
        var cancelled = false

        func summary(job: ConversionJob, items: [ConversionItem]) -> RunSummary {
            var seen = Set<String>()
            let inputBytes = items.reduce(UInt64(0)) { total, item in
                seen.insert(item.sourceURL.path).inserted ? total + item.byteSize : total
            }
            return RunSummary(
                target: job.label,
                outputs: outputs,
                converted: converted,
                skipped: items.filter { if case .skipped = $0.status { true } else { false } }.count,
                failed: failed,
                inputBytes: inputBytes,
                outputBytes: outputBytes
            )
        }
    }

    /// The one conversion loop. Stops between files when the surrounding task is cancelled;
    /// ffmpeg is killed mid-file by MediaConverter's own cancellation handler.
    private func execute(
        _ items: [ConversionItem],
        job: ConversionJob,
        update: (Int, ItemStatus, URL?) -> Void
    ) async -> RunTally {
        var tally = RunTally()
        for index in items.indices where items[index].status == .pending {
            if Task.isCancelled {
                tally.cancelled = true
                break
            }
            let item = items[index]
            guard let target = job.target(for: item) else {
                update(index, .skipped("No target for \(item.kind.label)"), nil)
                continue
            }
            update(index, .converting, nil)
            do {
                let result = try await service.convert(item, options: job.options(for: item, target: target))
                tally.outputs.append(result.url)
                tally.outputs.append(contentsOf: result.extras)
                tally.outputBytes += result.outputBytes
                tally.converted += 1
                update(index, .completed, result.url)
            } catch {
                if Task.isCancelled {
                    tally.cancelled = true
                    update(index, .pending, nil)
                    break
                }
                tally.failed += 1
                update(index, .failed(error.localizedDescription), nil)
            }
        }
        return tally
    }

    func undoLastRun() async {
        guard var summary = lastSummary, !summary.undone else { return }
        let result = await undo(summary)
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

    func applyRenames(_ renames: [Renamer.Rename]) async throws -> RunSummary {
        guard !isRunning else { throw ConversionError.writeFailed("Wait for the current run to finish.") }
        let pairs = try Renamer.apply(renames)
        let summary = RunSummary(
            target: "Rename",
            outputs: pairs.map { $0[1] },
            converted: pairs.count,
            skipped: 0,
            failed: 0,
            inputBytes: 0,
            outputBytes: 0,
            renames: pairs
        )
        try? await journal.save(summary)
        await replace(pairs.map { ($0[0], $0[1]) })
        return summary
    }

    func undoRename(_ summary: RunSummary) async {
        let result = await undo(summary)
        await replace((summary.renames ?? []).map { ($0[1], $0[0]) })
        if result.failed > 0 {
            present("Some names could not be restored", "\(result.failed) file(s) were moved or renamed since.")
        }
    }

    /// Swaps queue sources after a rename and replans.
    private func replace(_ moves: [(URL, URL)]) async {
        let map = Dictionary(moves.map { ($0.0.path, $0.1) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let urls = items.map { map[$0.sourceURL.path] ?? $0.sourceURL }.filter { seen.insert($0.path).inserted }
        await plan(urls: urls)
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
        // Watched conversions are silent by design; results and failures land in History.
        await quickRun(urls: [url], job: preset.job, showsProgress: false)
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
                pdfMode: pdfMode
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

    /// Files pass through untouched; folders are walked. Rust detection decides what's supported.
    nonisolated static func expandSynchronously(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else {
                result.append(url)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in enumerator
            where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(file)
            }
        }
        return result
    }
}
