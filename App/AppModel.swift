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

    /// The inline banner above the queue: run results, stops, undo outcomes and hints. Replaces modal alerts for anything recoverable.
    struct Notice: Identifiable {
        enum Tone { case success, warning, info }
        let id = UUID()
        var tone: Tone
        var title: String
        var detail: String?
        /// Set when the notice reports a run, so the banner can reveal, undo and retry.
        var summary: RunSummary?
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
    var selection = Set<UUID>()
    var notice: Notice?
    /// The file being converted right now, for the progress line.
    var currentItemName: String?
    /// Output sizes of finished rows, read once when each file completes.
    var outputSizes: [UUID: UInt64] = [:]
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
                && !removeBackground && maxPixelSize == nil
                && imageTargetBytes == nil && videoTargetBytes == nil
                && pdfMode == .pages
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
        // A preset is the whole recipe: clear the extras so the sidebar/inspector checkmark stays honest.
        removeBackground = false
        maxPixelSize = nil
        imageTargetBytes = nil
        videoTargetBytes = nil
        pdfMode = .pages
        scheduleReplan()
    }

    /// Why Convert is disabled, in words, or nil when it can run.
    var runBlockedReason: String? {
        if isRunning { return "A conversion is running." }
        if isPlanning { return "Preparing the files…" }
        if items.isEmpty { return "Add files first." }
        if runnableCount == 0 {
            return items.contains { $0.status == .completed } ? "Everything is converted. Change a setting to convert again." : "Nothing here can be converted with these settings."
        }
        return nil
    }

    var canRun: Bool { runBlockedReason == nil }

    var progress: Double {
        totalToConvert == 0 ? 0 : Double(completedCount) / Double(totalToConvert)
    }

    /// Where files go, in words, for the Output section and the bottom bar.
    var destinationDescription: String {
        if AppSettings.bool(AppSettings.useFolder) {
            return AppSettings.outputFolder().map { "In \($0.lastPathComponent)" } ?? "Output folder unavailable"
        }
        return "Next to the originals"
    }

    /// One planned output name, so the Output section can show a real example.
    var outputExample: String? {
        items.first { $0.status == .pending }.map { "\($0.displayName) → \($0.outputName)" }
    }

    func count(where predicate: (ItemStatus) -> Bool) -> Int {
        items.filter { predicate($0.status) }.count
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
        // Replanning mid-run would swap the rows the run loop is writing to.
        guard !isRunning else {
            inform(.info, "Wait for this conversion to finish", "Then drop the files again to add them.")
            return
        }
        Task {
            let expanded = await Self.expand(urls)
            guard !expanded.isEmpty else {
                inform(.warning, "No files found", "That folder is empty. Drop images, PDFs, audio, video, Office or data files.")
                return
            }
            guard !isRunning else { return }
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
            guard !Task.isCancelled, let self, !self.isRunning else { return }
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
        guard canRun else { return }
        notice = nil
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

        replanTask?.cancel()
        isRunning = true
        totalToConvert = pendingCount
        completedCount = 0
        defer {
            isRunning = false
            currentItemName = nil
        }

        let job = windowJob
        let tally = await execute(items, job: job) { index, status, output in
            self.items[index].status = status
            self.items[index].outputURL = output
            if status == .converting { self.currentItemName = self.items[index].displayName }
            if status.isTerminal { self.completedCount += 1 }
            if let output, status == .completed {
                self.outputSizes[self.items[index].id] = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)
            }
        }

        let summary = tally.summary(job: job, items: items)
        try? await journal.save(summary)
        if !tally.cancelled { NotificationService.shared.notify(summary) }
        lastSummary = summary
        showResult(summary, stopped: tally.cancelled)
        if !tally.cancelled { revealIfWanted(summary) }
    }

    /// Opens Finder on a finished run's outputs when Settings asks for it. Watch-folder runs never call this.
    func revealIfWanted(_ summary: RunSummary) {
        guard AppSettings.bool(AppSettings.revealWhenDone), !summary.undone else { return }
        let existing = summary.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }

    /// Reports a finished window or queue-header run in the banner.
    func showResult(_ summary: RunSummary, stopped: Bool = false) {
        var parts: [String] = []
        if summary.converted > 0 {
            parts.append(summary.bytesSaved > 0
                ? "\(ByteCount.string(UInt64(summary.bytesSaved))) saved"
                : "\(ByteCount.string(summary.outputBytes)) written")
        }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
        let files = "\(summary.converted) file\(summary.converted == 1 ? "" : "s")"
        let title: String
        if stopped {
            title = "Stopped · \(files) converted"
            parts.append("the rest are still in the queue")
        } else if summary.converted == 0 {
            title = "Nothing was converted"
        } else {
            title = "\(files) converted"
        }
        notice = Notice(
            tone: summary.failed > 0 || stopped || summary.converted == 0 ? .warning : .success,
            title: title,
            detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
            summary: summary
        )
    }

    func inform(_ tone: Notice.Tone, _ title: String, _ detail: String? = nil) {
        notice = Notice(tone: tone, title: title, detail: detail)
    }

    /// Failed rows go back to Ready so Convert picks them up again.
    func retryFailed() {
        guard !isRunning else { return }
        for index in items.indices {
            if case .failed = items[index].status { items[index].status = .pending }
        }
        notice = nil
        startRun()
    }

    /// Drops converted rows; the run stays undoable from History.
    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.status == .completed }
        selection.removeAll()
        notice = nil
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
        await quickRun(urls: urls, job: action.job(for: urls), showsProgress: showsProgress)
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
        if showsProgress {
            quickSummary = summary
            if !tally.cancelled { revealIfWanted(summary) }
        }
        return summary
    }

    func undo(_ summary: RunSummary) async -> (removed: Int, failed: Int) {
        // Opens sandbox access to the Settings folder in case the outputs sit there.
        // ponytail: only the current folder; store the bookmark on RunSummary if undo after switching folders matters.
        _ = AppSettings.bookmarkedFolder()
        let result = await service.undo(summary)
        guard result.failed == 0 else { return result }
        try? await journal.markUndone(id: summary.id)
        if quickSummary?.id == summary.id { quickSummary?.undone = true }
        return result
    }

    private struct RunTally {
        var outputs: [URL] = []
        var fileNumbers: [Int?] = []
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
                outputBytes: outputBytes,
                fileNumbers: fileNumbers
            )
        }
    }

    /// The one conversion loop, a few files at a time. Cancelling the surrounding task stops new starts
    /// and cancels files in flight; ffmpeg is killed mid-file by MediaConverter's own cancellation handler.
    private func execute(
        _ items: [ConversionItem],
        job: ConversionJob,
        update: (Int, ItemStatus, URL?) -> Void
    ) async -> RunTally {
        var tally = RunTally()
        var job = job
        job.outputDirectory = AppSettings.outputFolder()
        if AppSettings.bool(AppSettings.useFolder), job.outputDirectory == nil {
            // Never fall back silently: the user expects files in their folder.
            for index in items.indices where items[index].status == .pending {
                tally.failed += 1
                update(index, .failed("Output folder unavailable. Choose it again in Settings."), nil)
            }
            return tally
        }
        var waiting: [(index: Int, options: ConversionOptions, heavy: Bool)] = []
        for index in items.indices where items[index].status == .pending {
            let item = items[index]
            guard let target = job.target(for: item) else {
                update(index, .skipped("No target for \(item.kind.label)"), nil)
                continue
            }
            let options = job.options(for: item, target: target)
            // ffmpeg, CoreML, Vision and Quartz filters already fan out (or may not be thread-safe): one at a time.
            let heavy = item.kind == .audio || item.kind == .video || options.removeBackground
                || item.pdfMode == .searchable || item.pdfMode == .compress
            waiting.append((index, options, heavy))
        }

        // ponytail: light work runs up to 4 wide, which bounds peak RAM from big decoded images.
        let width = min(ProcessInfo.processInfo.activeProcessorCount, 4)
        let service = service
        typealias Outcome = (index: Int, heavy: Bool, result: Result<(url: URL, outputBytes: UInt64, extras: [URL]), any Error>)
        await withTaskGroup(of: Outcome.self) { group in
            var running = 0
            var heavyRunning = false
            while true {
                while running < width, !Task.isCancelled,
                      let next = waiting.firstIndex(where: { !$0.heavy || !heavyRunning }) {
                    let (index, options, heavy) = waiting.remove(at: next)
                    let item = items[index]
                    running += 1
                    if heavy { heavyRunning = true }
                    update(index, .converting, nil)
                    group.addTask {
                        do {
                            return (index, heavy, .success(try await service.convert(item, options: options)))
                        } catch {
                            return (index, heavy, .failure(error))
                        }
                    }
                }
                guard let outcome = await group.next() else { break }
                running -= 1
                if outcome.heavy { heavyRunning = false }
                switch outcome.result {
                case .success(let result):
                    tally.outputs.append(result.url)
                    tally.outputs.append(contentsOf: result.extras)
                    tally.fileNumbers += ([result.url] + result.extras).map(RunSummary.fileNumber)
                    tally.outputBytes += result.outputBytes
                    tally.converted += 1
                    update(outcome.index, .completed, result.url)
                case .failure where Task.isCancelled:
                    update(outcome.index, .pending, nil)
                case .failure(let error):
                    tally.failed += 1
                    update(outcome.index, .failed(error.localizedDescription), nil)
                }
            }
        }
        if Task.isCancelled { tally.cancelled = true }
        return tally
    }

    func undoLastRun() async {
        guard let summary = notice?.summary ?? lastSummary else { return }
        await undoRun(summary)
    }

    /// Undoes the run shown in the banner. Window-run rows go back to Ready; queue-header runs never touched the rows.
    func undoRun(_ summary: RunSummary) async {
        guard !summary.undone, !isRunning else { return }
        let result = await undo(summary)
        if lastSummary?.id == summary.id {
            lastSummary?.undone = true
            let outputs = Set(summary.outputs.map(\.path))
            for index in items.indices {
                guard items[index].status == .completed,
                      let url = items[index].outputURL, outputs.contains(url.path) else { continue }
                items[index].status = .pending
                items[index].outputURL = nil
                outputSizes[items[index].id] = nil
            }
        }
        showCompletion = false
        inform(
            result.failed == 0 ? .info : .warning,
            "Run undone",
            result.failed == 0
                ? "\(result.removed) new file\(result.removed == 1 ? "" : "s") moved to the Trash. Your originals weren't touched."
                : "\(result.removed) moved to the Trash; \(result.failed) couldn't be removed (moved or renamed since)."
        )
    }

    func reveal(_ summary: RunSummary) {
        guard !summary.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(summary.outputs)
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
        revealIfWanted(summary)
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

    func remove(_ ids: Set<UUID>) {
        guard !isRunning, !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func removeSelected() { remove(selection) }

    /// Rows that can never convert with these settings (unsupported kinds).
    var unsupportedIDs: Set<UUID> {
        Set(items.filter { $0.fidelity == .unsupported }.map(\.id))
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
        selection.removeAll()
        outputSizes.removeAll()
        notice = nil
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
