import Foundation
import FileFormatterRust
import PDFKit

public actor ConversionService {
    private let media = MediaConverter()
    /// Destinations claimed by conversions still in flight, so two runs into one folder never pick the same name.
    private var reserved = Set<String>()

    public init() {}

    /// Releases heavy cached models and PDF documents once batch work goes idle.
    public static func evictIdleCaches() {
        ImageTools.evictCachedModel()
        PDFPageRenderer.evictCache()
        PDFTools.evictCache()
    }

    public func makePlan(
        urls: [URL],
        targets: TargetRecipe,
        suffix: String,
        pdfMode: PDFMode = .pages,
        pdfTool: PDFToolRequest? = nil
    ) async throws -> PlanResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.planSynchronously(
                urls: urls,
                targets: targets,
                suffix: suffix,
                pdfMode: pdfMode,
                pdfTool: pdfTool
            )
        }.value
    }

    private nonisolated static func planSynchronously(
        urls: [URL],
        targets: TargetRecipe,
        suffix: String,
        pdfMode: PDFMode,
        pdfTool: PDFToolRequest?
    ) throws -> PlanResult {
        let suffix = suffix.filter { $0 != "/" && $0 != ":" && $0 != "\0" }
        var seen = Set<String>()
        let ordered = urls.compactMap { url -> URL? in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted ? url : nil
        }
        guard !ordered.isEmpty else {
            return PlanResult(items: [], warnings: [])
        }

        var warnings: [String] = []
        let rustPlan: FileFormatterRust.Plan
        do {
            rustPlan = try FileFormatterRust.buildMixedPlan(
                paths: ordered.map { $0.standardizedFileURL.path },
                targets: FileFormatterRust.PlanTargets(
                    image: targets.image.fileExtension,
                    data: targets.data.fileExtension,
                    document: targets.document.fileExtension,
                    audio: targets.audio.fileExtension,
                    video: targets.video.fileExtension
                ),
                suffix: suffix
            )
            warnings.append(contentsOf: rustPlan.warnings)
        } catch FileFormatterRust.CoreError.EmptyBatch {
            return PlanResult(
                items: [],
                warnings: ordered.map { "Skipped \($0.lastPathComponent): file not found" }
            )
        }

        var rustByPath: [String: FileFormatterRust.PlanItem] = [:]
        rustByPath.reserveCapacity(rustPlan.items.count)
        for item in rustPlan.items {
            let canonical = URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
            rustByPath[canonical] = item
        }

        var planned: [String: [ConversionItem]] = [:]

        var mergedPaths = Set<String>()
        if pdfMode == .merge {
            // One output from many inputs: every PDF, plus images when the image target is PDF.
            let mergeKinds: Set<FileKind> = targets.image == .pdf ? [.pdf, .image] : [.pdf]
            var sources: [URL] = []
            var totalBytes: UInt64 = 0
            for url in ordered {
                let key = url.standardizedFileURL.path
                if let rustItem = rustByPath[key], mergeKinds.contains(Self.map(rustItem.kind)) {
                    sources.append(url)
                    totalBytes += rustItem.byteSize
                    mergedPaths.insert(key)
                }
            }
            if let first = sources.first {
                let stem = first.deletingPathExtension().lastPathComponent
                planned[first.standardizedFileURL.path] = [ConversionItem(
                    sourceURL: first,
                    displayName: sources.count == 1 ? first.lastPathComponent : "\(sources.count) files",
                    kind: .pdf,
                    byteSize: totalBytes,
                    outputName: "\(stem)-merged.pdf",
                    fidelity: .lossless,
                    note: "Merge \(sources.count) file(s) into one PDF",
                    pdfMode: .merge,
                    mergeSources: sources
                )]
            }
        }

        for url in ordered {
            let key = url.standardizedFileURL.path
            if mergedPaths.contains(key) { continue }
            guard let item = rustByPath[key] else { continue }
            let kind = Self.map(item.kind)

            if kind == .pdf {
                if pdfMode != .pages {
                    do {
                        planned[key] = pdfMode == .split
                            ? try pdfPageItems(url: url, target: .pdf, suffix: suffix, mode: .split)
                            : [try wholePDFItem(url: url, suffix: suffix, mode: pdfMode, tool: pdfTool)]
                    } catch {
                        warnings.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
                        planned[key] = [skippedItem(url: url, kind: kind, byteSize: item.byteSize, reason: error.localizedDescription)]
                    }
                    continue
                }
                guard targets.image.family == .image else {
                    planned[key] = [skippedItem(url: url, kind: kind, byteSize: item.byteSize, reason: "Choose an image target for PDF pages")]
                    continue
                }
                do {
                    planned[key] = try pdfPageItems(url: url, target: targets.image, suffix: suffix, mode: .pages)
                } catch {
                    warnings.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
                    planned[key] = [skippedItem(url: url, kind: kind, byteSize: item.byteSize, reason: error.localizedDescription)]
                }
                continue
            }

            guard let target = targets.target(for: kind) else {
                planned[key] = [skippedItem(
                    url: url,
                    kind: kind,
                    byteSize: item.byteSize,
                    reason: "No target for \(kind.label) yet"
                )]
                continue
            }

            let sourceURL = URL(fileURLWithPath: item.sourcePath)
            let fidelity = Self.map(item.fidelity)
            let status: ItemStatus = fidelity == .unsupported
                ? .skipped("Unsupported for \(target.displayName)")
                : .pending
            planned[key] = [ConversionItem(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                kind: kind,
                byteSize: item.byteSize,
                outputName: item.outputName,
                fidelity: fidelity,
                note: item.note,
                status: status
            )]
        }

        let items = ordered.flatMap { planned[$0.standardizedFileURL.path] ?? [] }
        return PlanResult(items: items, warnings: warnings)
    }

    /// Compatibility entry point for callers that work with a single family.
    public func makePlan(
        urls: [URL],
        target: ConversionTarget,
        suffix: String
    ) async throws -> PlanResult {
        let recipe = TargetRecipe(
            image: target.family == .image ? target : .jpeg,
            data: target.family == .data ? target : .json,
            document: target.family == .document ? target : .markdown,
            audio: target.family == .audio ? target : .mp3,
            video: target.family == .video ? target : .mp4
        )
        return try await makePlan(urls: urls, targets: recipe, suffix: suffix)
    }

    /// Plans the toolkit: images keep their own format, PDFs get one tool operation per document.
    public func makeToolPlan(
        urls: [URL],
        imageEdit: ImageEdit?,
        pdfTool: PDFToolRequest?,
        suffix: String
    ) async throws -> PlanResult {
        await Task.detached(priority: .userInitiated) {
            Self.toolPlanSynchronously(urls: urls, imageEdit: imageEdit, pdfTool: pdfTool, suffix: suffix)
        }.value
    }

    private nonisolated static func toolPlanSynchronously(
        urls: [URL],
        imageEdit: ImageEdit?,
        pdfTool: PDFToolRequest?,
        suffix: String
    ) -> PlanResult {
        let suffix = suffix.filter { $0 != "/" && $0 != ":" && $0 != "\0" }
        var seen = Set<String>()
        let ordered = urls.compactMap { url -> URL? in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted ? url : nil
        }
        var items: [ConversionItem] = []
        var warnings: [String] = []

        for url in ordered {
            do {
                let info = try FileFormatterRust.detectFile(path: url.standardizedFileURL.path)
                let kind = Self.map(info.kind)
                if kind == .pdf, let pdfTool {
                    items.append(try wholePDFItem(
                        url: url,
                        suffix: suffix,
                        mode: pdfTool.kind == .text ? .text : .tool,
                        tool: pdfTool
                    ))
                } else if kind == .image, let imageEdit {
                    let target = ConversionTarget.imageTarget(forExtension: url.pathExtension)
                    guard target != .gif else {
                        warnings.append("Skipped \(url.lastPathComponent): animated GIFs are not edited.")
                        continue
                    }
                    let stem = url.deletingPathExtension().lastPathComponent
                    let lossless = target == .png || target == .tiff
                    items.append(ConversionItem(
                        sourceURL: url,
                        displayName: url.lastPathComponent,
                        kind: .image,
                        byteSize: info.byteSize,
                        outputName: "\(stem)\(suffix).\(target.fileExtension)",
                        fidelity: lossless ? .lossless : .reencode,
                        note: Self.describe(imageEdit),
                        status: .pending,
                        target: target
                    ))
                } else {
                    warnings.append("Skipped \(url.lastPathComponent): only images and PDFs use this tool.")
                }
            } catch {
                warnings.append("Skipped \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return PlanResult(items: items, warnings: warnings)
    }

    private static func describe(_ edit: ImageEdit) -> String {
        var parts: [String] = []
        if let aspect = edit.crop?.aspect, aspect > 0 { parts.append("Crop \(String(format: "%.2f", aspect)):1") }
        if edit.rotation % 360 != 0 { parts.append("Rotate \(((edit.rotation % 360) + 360) % 360)°") }
        switch edit.flip {
        case .horizontal: parts.append("Flip horizontal")
        case .vertical: parts.append("Flip vertical")
        case .none: break
        }
        return parts.isEmpty ? "Image edit" : parts.joined(separator: " · ")
    }

    public func convert(
        _ item: ConversionItem,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (url: URL, outputBytes: UInt64, extras: [URL]) {
        try Task.checkCancellation()
        let scoped = item.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { item.sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: item.sourceURL.path) else {
            throw ConversionError.cannotReadSource(item.displayName)
        }

        // The name is claimed on the actor; the work runs off it so conversions overlap.
        let destination = uniqueDestination(for: item, in: options.outputDirectory)
        reserved.insert(destination.path)
        defer { reserved.remove(destination.path) }
        let extras = try await Self.perform(item, options: options, destination: destination, media: media, progress: progress)

        let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values?.fileSize ?? 0)
        return (destination, size, extras)
    }

    @concurrent
    private static func perform(
        _ item: ConversionItem,
        options: ConversionOptions,
        destination: URL,
        media: MediaConverter,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        try Task.checkCancellation()
        var extras: [URL] = []
        switch (item.kind, options.target.family) {
        case (.pdf, _) where item.pdfMode == .text:
            try autoreleasepool {
                var tool = options.pdfTool ?? PDFToolRequest(kind: .text)
                if options.pdfTool == nil, [.markdown, .text, .html].contains(options.target) {
                    tool.textTarget = options.target
                }
                try PDFTools.apply(tool, source: item.sourceURL, destination: destination)
            }
        case (.pdf, _) where item.pdfMode == .tool:
            guard let tool = options.pdfTool else {
                throw ConversionError.unsupportedTarget("PDF tool")
            }
            try autoreleasepool {
                try PDFTools.apply(tool, source: item.sourceURL, destination: destination)
            }
        case (.pdf, _) where item.pdfMode == .merge:
            try autoreleasepool {
                try PDFTools.merge(sources: item.mergeSources ?? [item.sourceURL], destination: destination)
            }
        case (.pdf, _) where item.pdfMode == .searchable:
            try await searchablePDF(source: item.sourceURL, destination: destination, progress: progress)
        case (.pdf, _) where item.pdfMode == .split:
            guard let pageNumber = item.pageIndex else {
                throw ConversionError.unsupportedTarget("PDF page")
            }
            try autoreleasepool {
                try PDFTools.extractPage(source: item.sourceURL, pageNumber: pageNumber, destination: destination)
            }
        case (.pdf, _) where item.pdfMode == .compress:
            // A compress level always sets a size cap; without one, keep the system filter's own quality.
            try autoreleasepool {
                try PDFTools.compress(
                    source: item.sourceURL,
                    destination: destination,
                    quality: options.maxPixelSize == nil ? nil : options.quality,
                    maxPixelSize: options.maxPixelSize,
                    targetBytes: options.targetBytes
                )
            }
        case (.image, .image), (.image, .pdf):
            try autoreleasepool {
                if options.imageEdit != nil || options.removeBackground || options.maxPixelSize != nil || options.targetBytes != nil {
                    var (image, properties) = try ImageTools.load(item.sourceURL, maxPixelSize: options.maxPixelSize)
                    try Task.checkCancellation()
                    if let edit = options.imageEdit {
                        image = try ImageTools.apply(edit, to: image)
                        // Framing changed, so the original pixel dimensions no longer describe the output.
                        properties[kCGImagePropertyPixelWidth] = image.width
                        properties[kCGImagePropertyPixelHeight] = image.height
                    }
                    if options.removeBackground {
                        try Task.checkCancellation()
                        image = try ImageTools.removeBackground(image, hdModel: options.backgroundModel)
                    }
                    try Task.checkCancellation()
                    try ImageTools.encode(
                        image: image,
                        destination: destination,
                        target: options.target,
                        quality: options.quality,
                        properties: options.preserveMetadata ? properties : [:],
                        targetBytes: options.targetBytes
                    )
                } else {
                    try ImageConverter.convert(
                        source: item.sourceURL,
                        destination: destination,
                        target: options.target,
                        quality: options.quality,
                        preserveMetadata: options.preserveMetadata
                    )
                }
            }
        case (.pdf, .image):
            guard let pageNumber = item.pageIndex else {
                throw ConversionError.unsupportedTarget("PDF page")
            }
            try autoreleasepool {
                let image = try PDFPageRenderer.render(
                    source: item.sourceURL,
                    pageNumber: pageNumber
                )
                try Task.checkCancellation()
                try ImageConverter.encode(
                    image: image,
                    destination: destination,
                    target: options.target,
                    quality: options.quality
                )
            }
        case (.video, .image) where options.target == .gif:
            try await convertMedia(
                media,
                source: item.sourceURL,
                destination: destination,
                target: options.target,
                quality: options.quality,
                targetBytes: nil,
                background: options.backgroundPriority,
                progress: progress
            )
        case (.audio, .audio), (.video, .video), (.video, .audio):
            try await convertMedia(
                media,
                source: item.sourceURL,
                destination: destination,
                target: options.target,
                quality: options.quality,
                targetBytes: options.targetBytes,
                background: options.backgroundPriority,
                progress: progress
            )
        case (.data, .data):
            try convertData(
                source: item.sourceURL,
                destination: destination,
                target: options.target
            )
        case (.document, .document):
            extras = try extractOffice(
                source: item.sourceURL,
                destination: destination,
                target: options.target
            )
        default:
            throw ConversionError.unsupportedTarget(
                "\(item.kind.label) → \(options.target.displayName)"
            )
        }
        return extras
    }

    public func undo(_ summary: RunSummary) async -> (removed: Int, failed: Int) {
        var scopedFolder: URL?
        if let bookmark = summary.outputFolderBookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), resolved.startAccessingSecurityScopedResource() {
                scopedFolder = resolved
            }
        }
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }

        if let renames = summary.renames {
            let result = Renamer.revert(renames)
            return (result.restored, result.failed)
        }
        var removed = 0
        var failed = 0
        for (index, output) in summary.outputs.enumerated() {
            // Only trash the file this run wrote: a file copied or saved under the same name later is someone else's.
            if let numbers = summary.fileNumbers, numbers.count == summary.outputs.count,
               let recorded = numbers[index], let current = RunSummary.fileNumber(output), current != recorded {
                failed += 1
                continue
            }
            // No existence pre-check: without sandbox access a file looks missing, which must count as a failure.
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: output, resultingItemURL: &resulting)
                removed += 1
            } catch CocoaError.fileNoSuchFile {
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }

    private nonisolated static func pdfPageItems(
        url: URL,
        target: ConversionTarget,
        suffix: String,
        mode: PDFMode
    ) throws -> [ConversionItem] {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.cannotReadSource(url.lastPathComponent)
        }
        guard !document.isLocked else {
            throw ConversionError.cannotReadSource("\(url.lastPathComponent) is password-protected")
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ConversionError.cannotReadSource("\(url.lastPathComponent) has no pages")
        }

        let stem = url.deletingPathExtension().lastPathComponent
        let ext = target == .jpeg ? "jpg" : target.fileExtension
        let digits = max(2, String(pageCount).count)
        let totalBytes = fileSize(url)

        return (1...pageCount).map { page in
            let number = String(format: "%0\(digits)d", page)
            return ConversionItem(
                sourceURL: url,
                displayName: url.lastPathComponent,
                kind: .pdf,
                byteSize: page == 1 ? totalBytes : 0,
                outputName: "\(stem)\(suffix)-page-\(number).\(ext)",
                fidelity: .extract,
                note: "Page \(page) of \(pageCount)",
                status: .pending,
                pageIndex: page,
                pageCount: pageCount,
                pdfMode: mode
            )
        }
    }

    private static func convertMedia(
        _ media: MediaConverter,
        source: URL,
        destination: URL,
        target: ConversionTarget,
        quality: Double,
        targetBytes: UInt64?,
        background: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let format = MediaTarget(rawValue: target.rawValue) else {
            throw ConversionError.unsupportedTarget(target.displayName)
        }
        let directory = destination.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try await media.convert(
                source: source,
                destination: temporary,
                format: format,
                quality: quality,
                targetBytes: targetBytes,
                background: background,
                progress: progress
            )
        } catch let error as MediaError {
            if case .cancelled = error { throw CancellationError() }
            throw ConversionError.core(error.localizedDescription)
        } catch {
            throw ConversionError.core(error.localizedDescription)
        }
        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private nonisolated static func wholePDFItem(
        url: URL,
        suffix: String,
        mode: PDFMode,
        tool: PDFToolRequest? = nil
    ) throws -> ConversionItem {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.cannotReadSource(url.lastPathComponent)
        }
        // Tool runs may open a locked PDF with the password typed in the sheet; plain conversions cannot.
        let toolRun = mode == .tool || mode == .text
        if document.isLocked && !toolRun {
            throw ConversionError.cannotReadSource("\(url.lastPathComponent) is password-protected")
        }
        let pageCount = document.pageCount
        guard pageCount > 0 || toolRun else {
            throw ConversionError.cannotReadSource("\(url.lastPathComponent) has no pages")
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let textTarget = tool?.textTarget ?? .markdown
        let outputName: String
        let fidelity: FidelityLevel
        let note: String
        let target: ConversionTarget?
        switch mode {
        case .text:
            outputName = "\(stem)\(suffix).\(textTarget.fileExtension)"
            fidelity = .extract
            note = "Extract text · \(pageCount) page(s)"
            target = textTarget
        case .tool:
            outputName = "\(stem)\(suffix).pdf"
            fidelity = tool?.fidelity ?? .reencode
            note = "\(tool?.kind.label ?? "Edit PDF") · \(pageCount) page(s)"
            target = .pdf
        case .searchable:
            outputName = "\(stem)\(suffix)-ocr.pdf"
            fidelity = .reencode
            note = "\(mode.label) · \(pageCount) page(s)"
            target = nil
        default:
            outputName = "\(stem)\(suffix).pdf"
            fidelity = .reencode
            note = "\(mode.label) · \(pageCount) page(s)"
            target = nil
        }
        return ConversionItem(
            sourceURL: url,
            displayName: url.lastPathComponent,
            kind: .pdf,
            byteSize: fileSize(url),
            outputName: outputName,
            fidelity: fidelity,
            note: note,
            status: .pending,
            pageIndex: nil,
            pageCount: pageCount,
            pdfMode: mode,
            target: target
        )
    }

    private static func searchablePDF(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try OCRService().makeSearchablePDF(
                source: source,
                destination: temporary,
                progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversionError.core(error.localizedDescription)
        }
        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private static func convertData(
        source: URL,
        destination: URL,
        target: ConversionTarget
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension(target.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try FileFormatterRust.convertData(
                inputPath: source.path,
                outputPath: temporary.path,
                targetExtension: target.fileExtension
            )
        } catch {
            throw ConversionError.core(error.localizedDescription)
        }

        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private static func extractOffice(
        source: URL,
        destination: URL,
        target: ConversionTarget
    ) throws -> [URL] {
        // Written in place, not via a temp file: Rust names the image folder
        // "<output stem>_files" and links to it relatively.
        let stem = destination.deletingPathExtension().lastPathComponent
        let companion = destination.deletingLastPathComponent().appendingPathComponent(stem + "_files")
        let companionExisted = FileManager.default.fileExists(atPath: companion.path)

        do {
            try FileFormatterRust.extractOffice(
                inputPath: source.path,
                outputPath: destination.path,
                targetExtension: target.fileExtension
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.core(error.localizedDescription)
        }

        return !companionExisted && FileManager.default.fileExists(atPath: companion.path) ? [companion] : []
    }

    private nonisolated static func skippedItem(url: URL, kind: FileKind, byteSize: UInt64? = nil, reason: String) -> ConversionItem {
        ConversionItem(
            sourceURL: url,
            displayName: url.lastPathComponent,
            kind: kind,
            byteSize: byteSize ?? fileSize(url),
            outputName: url.lastPathComponent,
            fidelity: .unsupported,
            note: reason,
            status: .skipped(reason)
        )
    }

    private nonisolated static func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func uniqueDestination(for item: ConversionItem, in folder: URL?) -> URL {
        let directory = folder ?? item.sourceURL.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(item.outputName)

        if candidate.standardizedFileURL == item.sourceURL.standardizedFileURL {
            let base = item.sourceURL.deletingPathExtension().lastPathComponent
            let ext = (item.outputName as NSString).pathExtension
            candidate = directory.appendingPathComponent("\(base)-converted.\(ext)")
        }

        func taken(_ url: URL) -> Bool { reserved.contains(url.path) || FileManager.default.fileExists(atPath: url.path) }
        guard taken(candidate) else {
            return candidate
        }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...9999 {
            let numbered = directory.appendingPathComponent("\(base) \(index).\(ext)")
            if !taken(numbered) {
                return numbered
            }
        }
        return candidate
    }

    private static func map(_ kind: FileFormatterRust.FileKind) -> FileKind {
        switch kind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .pdf: .pdf
        case .document: .document
        case .data: .data
        case .archive: .archive
        case .unknown: .unknown
        }
    }

    private static func map(_ fidelity: FileFormatterRust.Fidelity) -> FidelityLevel {
        switch fidelity {
        case .lossless: .lossless
        case .reencode: .reencode
        case .lossy: .lossy
        case .extract: .extract
        case .unsupported: .unsupported
        }
    }
}
