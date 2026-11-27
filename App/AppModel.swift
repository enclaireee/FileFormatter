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
        /// True only when Retry Failed can act on the window queue, not on an unrelated tool run.
        var retryable = false
    }

    var items: [ConversionItem] = []
    var warnings: [String] = []
    var imageTarget: ConversionTarget = .jpeg
    var dataTarget: ConversionTarget = .json
    var documentTarget: ConversionTarget = .markdown
    var audioTarget: ConversionTarget = .mp3
    var videoTarget: ConversionTarget = .mp4
    var quality: Double = 0.85
    var suffix: String = ""
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
    /// Live 0...1 progress of the active heavy file (video, audio, multi-page OCR).
    var currentItemProgress: Double?
    /// Output sizes of finished rows, read once when each file completes.
    var outputSizes: [UUID: UInt64] = [:]
    var showImporter = false
    var showFolderImporter = false
    var showCompletion = false
    var showRename = false
    var lastSummary: RunSummary?
    var alert: AlertPayload?
    var watchRules: [WatchRule] = []
    var completedCount = 0
    var totalToConvert = 0

    // Incremental O(1) queue counters so SwiftUI views never re-scan `items` on every status tick.
    private(set) var pendingCount = 0
    private(set) var finishedCount = 0
    private(set) var skippedCount = 0
    private(set) var failedCount = 0
    private(set) var cachedInputBytes: UInt64 = 0
    private(set) var cachedPresentKinds: Set<FileKind> = []
    private(set) var cachedUnsupportedIDs: Set<UUID> = []
    private var indexByID: [UUID: Int] = [:]
    private var dynamicallyQueued: [ConversionItem] = []

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
    private var idleEvictTask: Task<Void, Never>?
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
                && preset.removeBackground == removeBackground
                && maxPixelSize == nil
                && imageTargetBytes == nil && videoTargetBytes == nil
                && preset.pdfMode == pdfMode
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
        removeBackground = preset.removeBackground
        maxPixelSize = nil
        imageTargetBytes = nil
        videoTargetBytes = nil
        pdfMode = preset.pdfMode
        scheduleReplan()
    }

    func pasteFromClipboard() {
        let urls = ClipboardImport.pasteURLs()
        guard !urls.isEmpty else {
            inform(.info, "Nothing to paste", "Copy files in Finder or take a screenshot to the clipboard first.")
            return
        }
        addFiles(urls)
    }

    func chooseOutputFolderInteractively() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = AppSettings.bookmarkedFolder()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url, (try? AppSettings.replaceOutputFolder(with: url)) != nil {
            UserDefaults.standard.set(true, forKey: AppSettings.useFolder)
        }
    }

    /// Why Convert is disabled, in words, or nil when it can run.
    var runBlockedReason: String? {
        if isRunning { return "A conversion is running." }
        if isQuickRunning { return "A quick action is still running." }
        if isPlanning { return "Preparing the files…" }
        if items.isEmpty { return "Add files first." }
        if runnableCount == 0 {
            return finishedCount > 0 ? "Everything is converted. Change a setting to convert again." : "Nothing here can be converted with these settings."
        }
        return nil
    }

    var canRun: Bool { runBlockedReason == nil }

    var progress: Double {
        guard totalToConvert > 0 else { return 0 }
        let partial = currentItemProgress ?? 0
        return min(1.0, (Double(completedCount) + partial) / Double(totalToConvert))
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
        cachedPresentKinds.contains(kind)
    }
    var runnableCount: Int { pendingCount }
    var inputBytes: UInt64 { cachedInputBytes }

    var fidelityCounts: [(FidelityLevel, Int)] {
        FidelityLevel.allCases.compactMap { level in
            let count = items.filter { $0.fidelity == level }.count
            return count > 0 ? (level, count) : nil
        }
    }

    private func rebuildQueueCaches() {
        var pending = 0
        var finished = 0
        var skipped = 0
        var failed = 0
        var bytes: UInt64 = 0
        var seenPaths = Set<String>()
        var kinds = Set<FileKind>()
        var unsupported = Set<UUID>()
        var map: [UUID: Int] = [:]
        map.reserveCapacity(items.count)

        for (idx, item) in items.enumerated() {
            map[item.id] = idx
            kinds.insert(item.kind)
            if item.fidelity == .unsupported {
                unsupported.insert(item.id)
            }
            if seenPaths.insert(item.sourceURL.path).inserted {
                bytes += item.byteSize
            }
            switch item.status {
            case .pending: pending += 1
            case .converting: break
            case .completed: finished += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            }
        }

        indexByID = map
        pendingCount = pending
        finishedCount = finished
        skippedCount = skipped
        failedCount = failed
        cachedInputBytes = bytes
        cachedPresentKinds = kinds
        cachedUnsupportedIDs = unsupported
    }

    private func adjustCounters(from old: ItemStatus, to new: ItemStatus) {
        if old == new { return }
        switch old {
        case .pending: pendingCount = max(0, pendingCount - 1)
        case .converting: break
        case .completed: finishedCount = max(0, finishedCount - 1)
        case .skipped: skippedCount = max(0, skippedCount - 1)
        case .failed: failedCount = max(0, failedCount - 1)
        }
        switch new {
        case .pending: pendingCount += 1
        case .converting: break
        case .completed: finishedCount += 1
        case .skipped: skippedCount += 1
        case .failed: failedCount += 1
        }
    }

    func addFiles(_ urls: [URL]) {
        if isRunning && pdfMode == .merge {
            inform(.info, "Wait for this PDF merge to finish", "Merging combines every file into one document.")
            return
        }
        Task {
            let expanded = await Self.expand(urls)
            guard !expanded.isEmpty else {
                inform(.warning, "No files found", "That folder is empty. Drop images, PDFs, audio, video, Office or data files.")
                return
            }
            let existing = Set(items.map { $0.sourceURL.standardizedFileURL.path })
            let new = expanded.filter { !existing.contains($0.standardizedFileURL.path) }
            guard !new.isEmpty else { return }

            if isRunning {
                do {
                    let result = try await service.makePlan(
                        urls: new,
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
                    guard !result.items.isEmpty || !result.warnings.isEmpty else { return }
                    items.append(contentsOf: result.items)
                    warnings.append(contentsOf: result.warnings)
                    rebuildQueueCaches()
                    if isRunning {
                        let newlyPending = result.items.filter { $0.status == .pending }
                        totalToConvert += newlyPending.count
                        dynamicallyQueued.append(contentsOf: newlyPending)
                    }
                } catch {
                    present(error: error)
                }
            } else {
                await plan(urls: items.map(\.sourceURL) + new)
            }
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
        guard pendingCount > 0 else { return }

        idleEvictTask?.cancel()
        replanTask?.cancel()
        dynamicallyQueued.removeAll()
        isRunning = true
        totalToConvert = pendingCount
        completedCount = 0
        currentItemProgress = nil
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Converting files")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            isRunning = false
            currentItemName = nil
            currentItemProgress = nil
            dynamicallyQueued.removeAll()
            scheduleIdleCacheEviction()
        }

        let job = windowJob
        let initialSnapshot = items
        let tally = await execute(
            initialSnapshot,
            job: job,
            allowDynamicQueue: true,
            updateStatus: { id, status, output in
                guard let index = self.indexByID[id] else { return }
                let oldStatus = self.items[index].status
                self.items[index].status = status
                self.items[index].outputURL = output
                if status != .converting {
                    self.items[index].progress = nil
                }
                self.adjustCounters(from: oldStatus, to: status)
                if status == .converting {
                    self.currentItemName = self.items[index].displayName
                    self.currentItemProgress = nil
                }
                if status.isTerminal {
                    self.completedCount += 1
                    self.currentItemProgress = nil
                }
                if let output, status == .completed {
                    self.outputSizes[id] = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)
                }
            },
            updateProgress: { id, fraction in
                guard let index = self.indexByID[id], self.items[index].status == .converting else { return }
                let previous = self.items[index].progress ?? 0
                guard fraction >= previous + 0.01 || fraction >= 1.0 else { return }
                self.items[index].progress = fraction
                self.currentItemProgress = fraction
            }
        )

        let bookmark = AppSettings.bool(AppSettings.useFolder)
            ? UserDefaults.standard.data(forKey: AppSettings.folderBookmark)
            : nil
        let summary = tally.summary(job: job, items: items, outputFolderBookmark: bookmark)
        try? await journal.save(summary)
        if !tally.cancelled { NotificationService.shared.notify(summary) }
        lastSummary = summary
        showResult(summary, stopped: tally.cancelled, retryable: summary.failed > 0)
        if !tally.cancelled { revealIfWanted(summary) }
    }

    private func scheduleIdleCacheEviction() {
        idleEvictTask?.cancel()
        idleEvictTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.isRunning, !self.isQuickRunning else { return }
            ConversionService.evictIdleCaches()
        }
    }

    /// Opens Finder on a finished run's outputs when Settings asks for it. Watch-folder runs never call this.
    func revealIfWanted(_ summary: RunSummary) {
        guard AppSettings.bool(AppSettings.revealWhenDone), !summary.undone else { return }
        let existing = summary.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }

    /// Reports a finished window or queue-header run in the banner.
    func showResult(_ summary: RunSummary, stopped: Bool = false, retryable: Bool = false) {
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
            summary: summary,
            retryable: retryable
        )
    }

    func inform(_ tone: Notice.Tone, _ title: String, _ detail: String? = nil) {
        notice = Notice(tone: tone, title: title, detail: detail)
    }

    /// Failed rows go back to Ready so Convert picks them up again.
    func retryFailed() {
        guard !isRunning else { return }
        for index in items.indices {
            if case .failed = items[index].status {
                items[index].status = .pending
                items[index].progress = nil
            }
        }
        rebuildQueueCaches()
        notice = nil
        startRun()
    }

    /// Drops converted rows; the run stays undoable from History.
    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.status == .completed }
        rebuildQueueCaches()
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

    /// Runs an Image Tools or PDF Tools job from the window and reports it in the usual banner.
    @discardableResult
    func runTool(urls: [URL], job: ConversionJob) async -> RunSummary? {
        guard !isBusy else {
            inform(.info, "Wait for the current run to finish", "Then run the tool again.")
            return nil
        }
        guard !urls.isEmpty else {
            inform(.warning, "Choose files first", "Add images or PDFs to the tool.")
            return nil
        }
        isQuickRunning = true
        defer { isQuickRunning = false }
        guard let summary = await performQuickRun(urls: urls, job: job, showsProgress: false) else {
            inform(.warning, "Couldn't run this tool", "The files may be unreadable or in an unsupported format.")
            return nil
        }
        lastSummary = summary
        showResult(summary)
        if !summary.undone { revealIfWanted(summary) }
        return summary
    }

    private func performQuickRun(urls: [URL], job: ConversionJob, showsProgress: Bool) async -> RunSummary? {
        let expanded = await Self.expand(urls)
        guard !expanded.isEmpty else { return nil }
        idleEvictTask?.cancel()
        let activity = job.backgroundPriority
            ? nil
            : ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Quick conversion")
        if showsProgress {
            isQuickRunning = true
            quickSummary = nil
        }
        defer {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            if showsProgress { isQuickRunning = false }
            scheduleIdleCacheEviction()
        }

        let plan: PlanResult
        do {
            plan = if job.isTool {
                try await service.makeToolPlan(
                    urls: expanded,
                    imageEdit: job.imageEdit,
                    pdfTool: job.pdfTool,
                    suffix: job.suffix
                )
            } else {
                try await service.makePlan(
                    urls: expanded,
                    targets: job.targets,
                    suffix: job.suffix,
                    pdfMode: job.pdfMode,
                    pdfTool: job.pdfTool
                )
            }
        } catch {
            if showsProgress { present(error: error) }
            return nil
        }

        var planned = plan.items
        let quickIndexByID = Dictionary(uniqueKeysWithValues: planned.enumerated().map { ($0.element.id, $0.offset) })
        if showsProgress { quickItems = planned }
        let tally = await execute(
            planned,
            job: job,
            allowDynamicQueue: false,
            updateStatus: { id, status, output in
                guard let index = quickIndexByID[id] else { return }
                planned[index].status = status
                planned[index].outputURL = output
                if status != .converting { planned[index].progress = nil }
                if showsProgress { self.quickItems = planned }
            },
            updateProgress: { id, fraction in
                guard showsProgress, let index = quickIndexByID[id], planned[index].status == .converting else { return }
                let previous = planned[index].progress ?? 0
                guard fraction >= previous + 0.02 || fraction >= 1.0 else { return }
                planned[index].progress = fraction
                self.quickItems = planned
            }
        )
        let bookmark = AppSettings.bool(AppSettings.useFolder)
            ? UserDefaults.standard.data(forKey: AppSettings.folderBookmark)
            : nil
        let summary = tally.summary(job: job, items: planned, outputFolderBookmark: bookmark)
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

        func summary(job: ConversionJob, items: [ConversionItem], outputFolderBookmark: Data? = nil) -> RunSummary {
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
                fileNumbers: fileNumbers,
                outputFolderBookmark: outputFolderBookmark
            )
        }
    }

    private enum WorkWeight {
        case light
        case largeImage
        case heavy
    }

    /// The one conversion loop, keyed by item UUID so files dropped mid-run join seamlessly.
    /// Cancelling the surrounding task stops new starts and cancels files in flight.
    private func execute(
        _ initialItems: [ConversionItem],
        job: ConversionJob,
        allowDynamicQueue: Bool,
        updateStatus: (UUID, ItemStatus, URL?) -> Void,
        updateProgress: @escaping @MainActor (UUID, Double) -> Void
    ) async -> RunTally {
        var tally = RunTally()
        var job = job
        job.outputDirectory = AppSettings.outputFolder()
        if AppSettings.bool(AppSettings.useFolder), job.outputDirectory == nil {
            // Never fall back silently: the user expects files in their folder.
            for item in initialItems where item.status == .pending {
                tally.failed += 1
                updateStatus(item.id, .failed("Output folder unavailable. Choose it again in Settings."), nil)
            }
            return tally
        }

        func prepare(_ item: ConversionItem) -> (item: ConversionItem, options: ConversionOptions, weight: WorkWeight)? {
            guard let target = job.target(for: item) else {
                updateStatus(item.id, .skipped("No target for \(item.kind.label)"), nil)
                return nil
            }
            let options = job.options(for: item, target: target)
            // ffmpeg, CoreML, Vision and Quartz filters already fan out (or may not be thread-safe): one at a time.
            let isHeavy = item.kind == .audio || item.kind == .video || options.removeBackground
                || item.pdfMode == .searchable || item.pdfMode == .compress
            let isLargeImage = !isHeavy && item.kind == .image
                && (item.byteSize > 12_000_000 || options.targetBytes != nil || options.target == .webp)
            let weight: WorkWeight = isHeavy ? .heavy : (isLargeImage ? .largeImage : .light)
            return (item, options, weight)
        }

        var waiting: [(item: ConversionItem, options: ConversionOptions, weight: WorkWeight)] = []
        for item in initialItems where item.status == .pending {
            if let entry = prepare(item) { waiting.append(entry) }
        }

        let width = job.backgroundPriority ? 2 : min(ProcessInfo.processInfo.activeProcessorCount, 4)
        let service = service
        typealias Outcome = (id: UUID, weight: WorkWeight, result: Result<(url: URL, outputBytes: UInt64, extras: [URL]), any Error>)
        await withTaskGroup(of: Outcome.self) { group in
            var running = 0
            var heavyRunning = false
            var largeImagesRunning = 0

            func canStart(_ weight: WorkWeight) -> Bool {
                switch weight {
                case .heavy: return !heavyRunning
                case .largeImage: return largeImagesRunning < 2
                case .light: return true
                }
            }

            while true {
                if allowDynamicQueue, !self.dynamicallyQueued.isEmpty {
                    let added = self.dynamicallyQueued
                    self.dynamicallyQueued.removeAll()
                    for item in added where item.status == .pending {
                        if let entry = prepare(item) { waiting.append(entry) }
                    }
                }
                while running < width, !Task.isCancelled,
                      let next = waiting.firstIndex(where: { canStart($0.weight) }) {
                    let (item, options, weight) = waiting.remove(at: next)
                    let id = item.id
                    running += 1
                    if weight == .heavy { heavyRunning = true }
                    if weight == .largeImage { largeImagesRunning += 1 }
                    updateStatus(id, .converting, nil)
                    let taskPriority: TaskPriority = job.backgroundPriority ? .utility : .userInitiated
                    group.addTask(priority: taskPriority) {
                        do {
                            let converted = try await service.convert(item, options: options) { fraction in
                                Task { @MainActor in
                                    updateProgress(id, fraction)
                                }
                            }
                            return (id, weight, .success(converted))
                        } catch {
                            return (id, weight, .failure(error))
                        }
                    }
                }
                guard let outcome = await group.next() else {
                    if allowDynamicQueue, !self.dynamicallyQueued.isEmpty {
                        let added = self.dynamicallyQueued
                        self.dynamicallyQueued.removeAll()
                        for item in added where item.status == .pending {
                            if let entry = prepare(item) { waiting.append(entry) }
                        }
                    }
                    if !Task.isCancelled && !waiting.isEmpty { continue }
                    break
                }
                running -= 1
                if outcome.weight == .heavy { heavyRunning = false }
                if outcome.weight == .largeImage { largeImagesRunning = max(0, largeImagesRunning - 1) }
                switch outcome.result {
                case .success(let result):
                    tally.outputs.append(result.url)
                    tally.outputs.append(contentsOf: result.extras)
                    tally.fileNumbers += ([result.url] + result.extras).map(RunSummary.fileNumber)
                    tally.outputBytes += result.outputBytes
                    tally.converted += 1
                    updateStatus(outcome.id, .completed, result.url)
                case .failure where Task.isCancelled:
                    updateStatus(outcome.id, .pending, nil)
                case .failure(let error):
                    tally.failed += 1
                    updateStatus(outcome.id, .failed(error.localizedDescription), nil)
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
                items[index].progress = nil
                items[index].outputURL = nil
                outputSizes[items[index].id] = nil
            }
            rebuildQueueCaches()
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
        rebuildQueueCaches()
        selection.subtract(ids)
    }

    func removeSelected() { remove(selection) }

    /// Rows that can never convert with these settings (unsupported kinds).
    var unsupportedIDs: Set<UUID> {
        cachedUnsupportedIDs
    }

    func addWatch(folder: URL, presetID: String) {
        let bookmark = try? folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let rule = WatchRule(
            name: folder.lastPathComponent,
            folderPath: folder.standardizedFileURL.path,
            presetID: presetID,
            folderBookmark: bookmark
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
        // Watched conversions are silent by design and run at utility QoS; record outputs first so FSEvents never re-triggers on them.
        var job = preset.job
        job.backgroundPriority = true
        let summary = await quickRun(urls: [url], job: job, showsProgress: false)
        if let outputs = summary?.outputs, !outputs.isEmpty {
            await watchService.recordGeneratedOutputs(outputs)
        }
        if let index = watchRules.firstIndex(where: { $0.id == rule.id }) {
            watchRules[index].lastEvent = .now
            saveWatchRules()
        }
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
        rebuildQueueCaches()
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
            rebuildQueueCaches()
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
            rebuildQueueCaches()
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
