import Foundation
import FileFormatterRust

public actor ConversionService {
    public init() {}

    public func makePlan(
        urls: [URL],
        target: ConversionTarget,
        suffix: String
    ) throws -> PlanResult {
        var seen = Set<String>()
        let paths = urls.compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
        guard !paths.isEmpty else {
            return PlanResult(items: [], warnings: [])
        }

        let plan: FileFormatterRust.Plan
        do {
            plan = try FileFormatterRust.buildPlan(
                paths: paths,
                targetExtension: target.fileExtension,
                suffix: suffix
            )
        } catch {
            throw ConversionError.core(Self.describe(error))
        }

        let items = plan.items.map { planned -> ConversionItem in
            let sourceURL = URL(fileURLWithPath: planned.sourcePath)
            let fidelity = Self.map(planned.fidelity)
            let status: ItemStatus = fidelity == .unsupported
                ? .skipped("Unsupported for \(target.displayName)")
                : .pending
            return ConversionItem(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                kind: Self.map(planned.kind),
                byteSize: planned.byteSize,
                outputName: planned.outputName,
                fidelity: fidelity,
                note: planned.note,
                status: status
            )
        }
        return PlanResult(items: items, warnings: plan.warnings)
    }

    public func convert(
        _ item: ConversionItem,
        options: ConversionOptions
    ) async throws -> (url: URL, outputBytes: UInt64) {
        let scoped = item.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { item.sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard item.kind == .image else {
            throw ConversionError.unsupportedTarget(item.kind.label)
        }
        guard FileManager.default.fileExists(atPath: item.sourceURL.path) else {
            throw ConversionError.cannotReadSource(item.displayName)
        }

        let destination = uniqueDestination(for: item)
        try ImageConverter.convert(
            source: item.sourceURL,
            destination: destination,
            target: options.target,
            quality: options.quality,
            preserveMetadata: options.preserveMetadata
        )

        let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values?.fileSize ?? 0)
        return (destination, size)
    }

    public func undo(_ summary: RunSummary) async -> (removed: Int, failed: Int) {
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

    private func uniqueDestination(for item: ConversionItem) -> URL {
        let directory = item.sourceURL.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(item.outputName)

        if candidate.standardizedFileURL == item.sourceURL.standardizedFileURL {
            let base = item.sourceURL.deletingPathExtension().lastPathComponent
            let ext = item.outputName as NSString
            candidate = directory.appendingPathComponent(
                "\(base)-converted.\(ext.pathExtension)"
            )
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

    private static func describe(_ error: Error) -> String {
        if let core = error as? FileFormatterRust.CoreError {
            return String(describing: core)
        }
        return error.localizedDescription
    }
}
