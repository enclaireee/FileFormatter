import Foundation
import FileFormatterRust
import PDFKit

public actor ConversionService {
    private let media = MediaConverter()

    public init() {}

    public func makePlan(
        urls: [URL],
        targets: TargetRecipe,
        suffix: String,
        pdfMode: PDFMode = .pages
    ) throws -> PlanResult {
        var seen = Set<String>()
        let ordered = urls.compactMap { url -> URL? in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted ? url : nil
        }
        guard !ordered.isEmpty else {
            return PlanResult(items: [], warnings: [])
        }

        var warnings: [String] = []
        var grouped: [FileKind: [URL]] = [:]

        for url in ordered {
            do {
                let info = try FileFormatterRust.detectFile(path: url.standardizedFileURL.path)
                grouped[Self.map(info.kind), default: []].append(url)
            } catch {
                warnings.append("Skipped \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        var planned: [String: [ConversionItem]] = [:]

        if pdfMode == .merge {
            // One output from many inputs: every PDF, plus images when the image target is PDF.
            let mergeKinds: Set<FileKind> = targets.image == .pdf ? [.pdf, .image] : [.pdf]
            let sources = ordered.filter { url in
                mergeKinds.contains { grouped[$0]?.contains(url) == true }
            }
            if let first = sources.first {
                for kind in mergeKinds { grouped[kind] = nil }
                let stem = first.deletingPathExtension().lastPathComponent
                planned[first.standardizedFileURL.path] = [ConversionItem(
                    sourceURL: first,
                    displayName: sources.count == 1 ? first.lastPathComponent : "\(sources.count) files",
                    kind: .pdf,
                    byteSize: sources.reduce(0) { $0 + fileSize($1) },
                    outputName: "\(stem)-merged.pdf",
                    fidelity: .lossless,
                    note: "Merge \(sources.count) file(s) into one PDF",
                    pdfMode: .merge,
                    mergeSources: sources
                )]
            }
        }

        for (kind, group) in grouped {
            if kind == .pdf {
                for url in group {
                    let key = url.standardizedFileURL.path
                    if pdfMode != .pages {
                        do {
                            planned[key] = pdfMode == .split
                                ? try pdfPageItems(url: url, target: .pdf, suffix: suffix, mode: .split)
                                : [try wholePDFItem(url: url, suffix: suffix, mode: pdfMode)]
                        } catch {
                            warnings.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
                            planned[key] = [skippedItem(
                                url: url,
                                kind: kind,
                                reason: error.localizedDescription
                            )]
                        }
                        continue
                    }
                    guard targets.image.family == .image else {
                        planned[key] = [skippedItem(
                            url: url,
                            kind: kind,
                            reason: "Choose an image target for PDF pages"
                        )]
                        continue
                    }
                    do {
                        planned[key] = try pdfPageItems(
                            url: url,
                            target: targets.image,
                            suffix: suffix,
                            mode: .pages
                        )
                    } catch {
                        warnings.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
                        planned[key] = [skippedItem(
                            url: url,
                            kind: kind,
                            reason: error.localizedDescription
                        )]
                    }
                }
                continue
            }

            guard let target = targets.target(for: kind) else {
                for url in group {
                    planned[url.standardizedFileURL.path] = [skippedItem(
                        url: url,
                        kind: kind,
                        reason: "No target for \(kind.label) yet"
                    )]
                }
                continue
            }

            do {
                let plan = try FileFormatterRust.buildPlan(
                    paths: group.map { $0.standardizedFileURL.path },
                    targetExtension: target.fileExtension,
                    suffix: suffix
                )
                warnings.append(contentsOf: plan.warnings)

                for item in plan.items {
                    let sourceURL = URL(fileURLWithPath: item.sourcePath)
                    let fidelity = Self.map(item.fidelity)
                    let status: ItemStatus = fidelity == .unsupported
                        ? .skipped("Unsupported for \(target.displayName)")
                        : .pending
                    planned[sourceURL.standardizedFileURL.path] = [ConversionItem(
                        sourceURL: sourceURL,
                        displayName: sourceURL.lastPathComponent,
                        kind: Self.map(item.kind),
                        byteSize: item.byteSize,
                        outputName: item.outputName,
                        fidelity: fidelity,
                        note: item.note,
                        status: status
                    )]
                }
            } catch {
                let reason = error.localizedDescription
                for url in group {
                    warnings.append("Could not plan \(url.lastPathComponent): \(reason)")
                    planned[url.standardizedFileURL.path] = [skippedItem(
                        url: url,
                        kind: kind,
                        reason: reason
                    )]
                }
            }
        }

        let items = ordered.flatMap { planned[$0.standardizedFileURL.path] ?? [] }
        return PlanResult(items: items, warnings: warnings)
    }

    /// Compatibility entry point for callers that work with a single family.
    public func makePlan(
        urls: [URL],
        target: ConversionTarget,
        suffix: String
    ) throws -> PlanResult {
        let recipe = TargetRecipe(
            image: target.family == .image ? target : .jpeg,
            data: target.family == .data ? target : .json,
            document: target.family == .document ? target : .markdown,
            audio: target.family == .audio ? target : .mp3,
            video: target.family == .video ? target : .mp4
        )
        return try makePlan(urls: urls, targets: recipe, suffix: suffix)
    }

    public func convert(
        _ item: ConversionItem,
        options: ConversionOptions
    ) async throws -> (url: URL, outputBytes: UInt64, extras: [URL]) {
        let scoped = item.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { item.sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: item.sourceURL.path) else {
            throw ConversionError.cannotReadSource(item.displayName)
        }

        let destination = uniqueDestination(for: item)
        var extras: [URL] = []

        switch (item.kind, options.target.family) {
        case (.pdf, _) where item.pdfMode == .merge:
            try PDFTools.merge(sources: item.mergeSources ?? [item.sourceURL], destination: destination)
        case (.pdf, _) where item.pdfMode == .searchable:
            try await searchablePDF(source: item.sourceURL, destination: destination)
        case (.pdf, _) where item.pdfMode == .split:
            guard let pageNumber = item.pageIndex else {
                throw ConversionError.unsupportedTarget("PDF page")
            }
            try PDFTools.extractPage(source: item.sourceURL, pageNumber: pageNumber, destination: destination)
        case (.pdf, _) where item.pdfMode == .compress:
            try PDFTools.compress(source: item.sourceURL, destination: destination)
        case (.image, .image), (.image, .pdf):
            if options.removeBackground || options.maxPixelSize != nil || options.targetBytes != nil {
                var (image, properties) = try ImageTools.load(item.sourceURL, maxPixelSize: options.maxPixelSize)
                if options.removeBackground {
                    image = try ImageTools.removeBackground(image)
                }
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
        case (.pdf, .image):
            guard let pageNumber = item.pageIndex else {
                throw ConversionError.unsupportedTarget("PDF page")
            }
            let image = try PDFPageRenderer.render(
                source: item.sourceURL,
                pageNumber: pageNumber
            )
            try ImageConverter.encode(
                image: image,
                destination: destination,
                target: options.target,
                quality: options.quality
            )
        case (.video, .image) where options.target == .gif:
            try await convertMedia(
                source: item.sourceURL,
                destination: destination,
                target: options.target,
                quality: options.quality,
                targetBytes: nil
            )
        case (.audio, .audio), (.video, .video), (.video, .audio):
            try await convertMedia(
                source: item.sourceURL,
                destination: destination,
                target: options.target,
                quality: options.quality,
                targetBytes: options.targetBytes
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

        let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values?.fileSize ?? 0)
        return (destination, size, extras)
    }

    public func undo(_ summary: RunSummary) async -> (removed: Int, failed: Int) {
        if let renames = summary.renames {
            let result = Renamer.revert(renames)
            return (result.restored, result.failed)
        }
        var removed = 0
        var failed = 0
        for output in summary.outputs {
            guard FileManager.default.fileExists(atPath: output.path) else {
                removed += 1
                continue
            }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: output, resultingItemURL: &resulting)
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }

    private func pdfPageItems(
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

    private func convertMedia(
        source: URL,
        destination: URL,
        target: ConversionTarget,
        quality: Double,
        targetBytes: UInt64?
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
                targetBytes: targetBytes
            )
        } catch {
            throw ConversionError.core(error.localizedDescription)
        }
        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private func wholePDFItem(url: URL, suffix: String, mode: PDFMode) throws -> ConversionItem {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.cannotReadSource(url.lastPathComponent)
        }
        guard !document.isLocked else {
            throw ConversionError.cannotReadSource("\(url.lastPathComponent) is password-protected")
        }
        guard document.pageCount > 0 else {
            throw ConversionError.cannotReadSource("\(url.lastPathComponent) has no pages")
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return ConversionItem(
            sourceURL: url,
            displayName: url.lastPathComponent,
            kind: .pdf,
            byteSize: fileSize(url),
            outputName: mode == .searchable ? "\(stem)\(suffix)-ocr.pdf" : "\(stem)\(suffix).pdf",
            fidelity: .reencode,
            note: "\(mode.label) · \(document.pageCount) page(s)",
            status: .pending,
            pageIndex: nil,
            pageCount: document.pageCount,
            pdfMode: mode
        )
    }

    private func searchablePDF(source: URL, destination: URL) async throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try await OCRService().makeSearchablePDF(
                source: source,
                destination: temporary
            )
        } catch {
            throw ConversionError.core(error.localizedDescription)
        }
        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private func convertData(
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

    private func extractOffice(
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

    private func skippedItem(url: URL, kind: FileKind, reason: String) -> ConversionItem {
        ConversionItem(
            sourceURL: url,
            displayName: url.lastPathComponent,
            kind: kind,
            byteSize: fileSize(url),
            outputName: url.lastPathComponent,
            fidelity: .unsupported,
            note: reason,
            status: .skipped(reason)
        )
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func uniqueDestination(for item: ConversionItem) -> URL {
        let directory = item.sourceURL.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(item.outputName)

        if candidate.standardizedFileURL == item.sourceURL.standardizedFileURL {
            let base = item.sourceURL.deletingPathExtension().lastPathComponent
            let ext = (item.outputName as NSString).pathExtension
            candidate = directory.appendingPathComponent("\(base)-converted.\(ext)")
        }

        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...9999 {
            let numbered = directory.appendingPathComponent("\(base) \(index).\(ext)")
            if !FileManager.default.fileExists(atPath: numbered.path) {
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
