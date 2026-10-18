import AppKit
import FileFormatterCore
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    struct AlertPayload: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var items: [ConversionItem] = []
    var warnings: [String] = []
    var target: ConversionTarget = .jpeg
    var quality: Double = 0.85
    var suffix: String = "-converted"
    var preserveMetadata = true

    var isPlanning = false
    var isRunning = false
    var selectedID: UUID?
    var showImporter = false
    var showCompletion = false
    var lastSummary: RunSummary?
    var alert: AlertPayload?
    var completedCount = 0
    var totalToConvert = 0

    private let service = ConversionService()
    private let journal = RunJournal.shared
    private var replanTask: Task<Void, Never>?

    var isEmpty: Bool { items.isEmpty }
    var runnableCount: Int { items.filter { $0.status == .pending }.count }
    var inputBytes: UInt64 { items.reduce(0) { $0 + $1.byteSize } }

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
                    "Drop images or PDFs. Audio, video, and data arrive in the next milestones."
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

        let options = ConversionOptions(
            target: target,
            quality: quality,
            suffix: suffix,
            preserveMetadata: preserveMetadata
        )

        var outputs: [URL] = []
        var converted = 0
        var skipped = items.filter { item in
            if case .skipped = item.status { true } else { false }
        }.count
        var failed = 0
        var outputBytes: UInt64 = 0

        for index in items.indices {
            guard items[index].status == .pending else { continue }
            items[index].status = .converting
            do {
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

        let summary = RunSummary(
            target: target.displayName,
            outputs: outputs,
            converted: converted,
            skipped: skipped,
            failed: failed,
            inputBytes: items.reduce(0) { $0 + $1.byteSize },
            outputBytes: outputBytes
        )
        try? await journal.save(summary)
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
            let result = try await service.makePlan(urls: urls, target: target, suffix: suffix)
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
