import AppKit
import FileFormatterCore
import Foundation
import UniformTypeIdentifiers

/// Reads copied files or raw screenshot/image bitmaps from the macOS clipboard for 1-click Paste (`⌘V`).
@MainActor
enum ClipboardImport {
    nonisolated static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FileFormatterClipboard", isDirectory: true)
    }

    nonisolated static func isClipboardStaged(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(stagingDirectory.standardizedFileURL.path)
    }

    static func hasPasteableContent() -> Bool {
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return pb.availableType(from: [.png, .tiff]) != nil
    }

    static func pasteURLs() -> [URL] {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        let pngData: Data? = if let directPNG = pb.data(forType: .png) {
            directPNG
        } else if let tiffData = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiffData) {
            rep.representation(using: .png, properties: [:])
        } else {
            nil
        }
        guard let pngData else { return [] }
        let folder = stagingDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let fileURL = folder.appendingPathComponent("Pasted-Image-\(formatter.string(from: .now)).png")
        do {
            try pngData.write(to: fileURL, options: .atomic)
            return [fileURL]
        } catch {
            return []
        }
    }
}

/// Everything one conversion run needs, independent of the window's state.
struct ConversionJob: Sendable {
    var label: String
    var targets = TargetRecipe()
    var pdfMode: PDFMode = .pages
    var suffix = ""
    var quality = 0.85
    var preserveMetadata = true
    var maxPixelSize: Int?
    var imageTargetBytes: UInt64?
    var mediaTargetBytes: UInt64?
    /// Video/audio goal as a share of each file's size (Compress Light/Balanced/Strong).
    var mediaTargetRatio: Double?
    var removeBackground = false
    /// Set for toolkit runs; one edit applies to every image in the batch.
    var imageEdit: ImageEdit?
    /// Set for toolkit runs; one operation applies to every PDF in the batch.
    var pdfTool: PDFToolRequest?
    /// Set per run from Settings; nil writes next to the source.
    var outputDirectory: URL?
    /// True for background watch-folder conversions so child codecs run with utility priority.
    var backgroundPriority = false

    var isTool: Bool { imageEdit != nil || pdfTool != nil }

    func target(for item: ConversionItem) -> ConversionTarget? {
        if let target = item.target { return target }
        if item.kind == .pdf {
            if item.pdfMode == .searchable { return .searchablePDF }
            if item.pdfMode == .text { return pdfTool?.textTarget ?? .markdown }
            if item.pdfMode != .pages { return .pdf }
            return targets.image.family == .image ? targets.image : nil
        }
        return targets.target(for: item.kind)
    }

    func options(for item: ConversionItem, target: ConversionTarget) -> ConversionOptions {
        let still = item.kind == .image || item.kind == .pdf
        let goal = still
            ? imageTargetBytes
            : mediaTargetBytes ?? mediaTargetRatio.map { UInt64(Double(item.byteSize) * $0) }
        let effectiveOutputDir = outputDirectory ?? (
            ClipboardImport.isClipboardStaged(item.sourceURL)
                ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                : nil
        )
        return ConversionOptions(
            target: target,
            quality: quality,
            suffix: suffix,
            preserveMetadata: preserveMetadata,
            maxPixelSize: still ? maxPixelSize : nil,
            // Already under the size goal: convert normally instead of squeezing.
            targetBytes: goal.flatMap { item.byteSize > $0 ? $0 : nil },
            removeBackground: item.kind == .image && removeBackground,
            backgroundModel: AppSettings.backgroundModel,
            imageEdit: item.kind == .image ? imageEdit : nil,
            pdfTool: item.kind == .pdf ? pdfTool : nil,
            outputDirectory: effectiveOutputDir,
            backgroundPriority: backgroundPriority
        )
    }
}

/// One-click actions shared by the menu bar popover, Finder services and the queue header.
enum QuickAction: Hashable, Identifiable, Sendable {
    case to(ConversionTarget)
    case removeBackground
    case compressImage
    case makePDF
    case splitPDF
    case compressPDF
    case ocr
    case videoToGIF
    case extractAudio
    case compressVideo

    var id: String {
        switch self {
        case .to(let target): "to-\(target.rawValue)"
        case .removeBackground: "remove-background"
        case .compressImage: "compress-image"
        case .makePDF: "make-pdf"
        case .splitPDF: "split-pdf"
        case .compressPDF: "compress-pdf"
        case .ocr: "ocr"
        case .videoToGIF: "video-gif"
        case .extractAudio: "extract-audio"
        case .compressVideo: "compress-video"
        }
    }

    init?(id: String) {
        if id.hasPrefix("to-") {
            guard let target = ConversionTarget(rawValue: String(id.dropFirst(3))) else { return nil }
            self = .to(target)
            return
        }
        let all: [QuickAction] = [
            .removeBackground, .compressImage, .makePDF, .splitPDF, .compressPDF,
            .ocr, .videoToGIF, .extractAudio, .compressVideo
        ]
        guard let match = all.first(where: { $0.id == id }) else { return nil }
        self = match
    }

    var actionTitle: String {
        switch self {
        case .to(let target):
            let short = target.displayName.components(separatedBy: " (").first ?? target.displayName
            return "Convert to \(short)"
        default:
            return title
        }
    }

    var title: String {
        switch self {
        case .to(let target): target.displayName.components(separatedBy: " (").first ?? target.displayName
        case .removeBackground: "Remove Background"
        case .compressImage: "Compress"
        case .makePDF: "Make PDF"
        case .splitPDF: "Split Pages"
        case .compressPDF: "Compress PDF"
        case .ocr: "Make Searchable"
        case .videoToGIF: "GIF"
        case .extractAudio: "Extract Audio"
        case .compressVideo: "Compress"
        }
    }

    var systemImage: String {
        switch self {
        case .to(let target):
            switch target.family {
            case .image: "photo"
            case .data: "tablecells"
            case .document: "doc.text"
            case .audio: "waveform"
            case .video: "film"
            case .pdf: "doc.richtext"
            case .other: "arrow.right.circle"
            }
        case .removeBackground: "person.crop.rectangle.badge.plus"
        case .compressImage: "arrow.down.right.and.arrow.up.left"
        case .makePDF: "doc.on.doc"
        case .splitPDF: "square.split.2x1"
        case .compressPDF: "arrow.down.doc"
        case .ocr: "text.viewfinder"
        case .videoToGIF: "photo.stack"
        case .extractAudio: "music.note"
        case .compressVideo: "arrow.down.circle"
        }
    }

    func job(for urls: [URL]) -> ConversionJob {
        var job = ConversionJob(label: title)
        job.suffix = AppSettings.suffix(AppSettings.convertSuffix)
        job.preserveMetadata = AppSettings.bool(AppSettings.keepMetadata)
        switch self {
        case .to(let target):
            switch target.family {
            case .image: job.targets.image = target
            case .data: job.targets.data = target
            case .document: job.targets.document = target
            // Audio targets also apply to video files, so "MP3" on a movie extracts its sound.
            case .audio: job.targets.audio = target; job.targets.video = target
            case .video: job.targets.video = target
            case .pdf: job.targets.image = .pdf; job.pdfMode = .merge
            case .other: break
            }
        case .removeBackground:
            job.targets.image = .png
            job.removeBackground = true
            job.suffix = AppSettings.suffix(AppSettings.backgroundSuffix)
        case .compressImage, .compressPDF, .compressVideo:
            return CompressSettings.saved.job(for: self, urls: urls)
        case .makePDF:
            job.targets.image = .pdf
            job.pdfMode = .merge
        case .splitPDF:
            job.pdfMode = .split
        case .ocr:
            job.pdfMode = .searchable
        case .videoToGIF:
            job.targets.video = .gif
        case .extractAudio:
            job.targets.video = .mp3
            job.targets.audio = .mp3
        }
        return job
    }

    /// The likely actions for a set of dropped files, best first; the last one used for this kind leads.
    static func suggestions(for urls: [URL], limit: Int = 8) -> [QuickAction] {
        var result = defaults(for: urls)
        if let key = memoryKey(urls), let id = UserDefaults.standard.string(forKey: key),
           let last = QuickAction(id: id), (result + otherFormats(for: urls)).contains(last) {
            result.insert(last, at: 0)
        }
        var seen = Set<QuickAction>()
        return Array(result.filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// Remembers the choice so the same kind of file suggests it first next time.
    static func remember(_ action: QuickAction, for urls: [URL]) {
        guard let key = memoryKey(urls) else { return }
        UserDefaults.standard.set(action.id, forKey: key)
    }

    // ponytail: keyed by the first file's kind; mixed drops just follow that file.
    private static func memoryKey(_ urls: [URL]) -> String? {
        guard let first = urls.first else { return nil }
        let kind = kind(of: first)
        return kind == .unknown ? nil : "lastQuickAction.\(kind.rawValue)"
    }

    /// Plain format conversions that make sense for the dropped kinds, for the "More formats" menu.
    static func otherFormats(for urls: [URL]) -> [QuickAction] {
        let kinds = Set(urls.map(kind(of:)))
        let extensions = Set(urls.map { normalizedExtension($0.pathExtension) })
        let singleExt = extensions.count == 1 ? extensions.first : nil

        var families: [FormatFamily] = []
        if kinds.contains(.image) || kinds.contains(.pdf) { families += [.image] }
        if kinds.contains(.video) { families += [.video, .audio] }
        if kinds.contains(.audio) { families += [.audio] }
        if kinds.contains(.data) { families += [.data] }
        if kinds.contains(.document) { families += [.document] }
        var result = ConversionTarget.allCases
            .filter { target in
                guard families.contains(target.family),
                      target != .searchablePDF,
                      !(target == .gif && !kinds.contains(.image)) else { return false }
                // Don't offer converting a homogeneous drop to the exact format it already has.
                if let singleExt, normalizedExtension(target.fileExtension) == singleExt {
                    return false
                }
                return true
            }
            .map(QuickAction.to)
        if kinds.contains(.video) { result.append(.videoToGIF) }
        return result
    }

    private static func normalizedExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg", "jpe": "jpg"
        case "tif": "tiff"
        case "heif": "heic"
        case "yml": "yaml"
        case "markdown": "md"
        case "aif": "aiff"
        default: ext.lowercased()
        }
    }

    private static func defaults(for urls: [URL]) -> [QuickAction] {
        let extensions = Set(urls.map { normalizedExtension($0.pathExtension) })
        let kinds = Set(urls.map(kind(of:)))
        var result: [QuickAction] = []

        if kinds.contains(.image) {
            let onlyJPG = extensions == ["jpg"]
            let onlyPNG = extensions == ["png"]
            let onlyWebP = extensions == ["webp"]
            if onlyJPG {
                result += [.compressImage, .to(.webp), .to(.png), .makePDF, .removeBackground]
            } else if onlyPNG {
                result += [.to(.webp), .removeBackground, .compressImage, .to(.jpeg), .makePDF]
            } else if onlyWebP {
                result += [.to(.png), .to(.jpeg), .removeBackground, .compressImage, .makePDF]
            } else {
                result += [.to(.jpeg), .removeBackground, .compressImage, .to(.png), .to(.webp), .makePDF]
            }
        }
        if kinds.contains(.pdf) {
            let pdfCount = urls.filter { kind(of: $0) == .pdf }.count
            result += pdfCount > 1 ? [.makePDF, .compressPDF, .to(.png), .splitPDF] : [.compressPDF, .to(.png), .ocr, .splitPDF]
        }
        if kinds.contains(.video) {
            let onlyMP4 = extensions == ["mp4"]
            if onlyMP4 {
                result += [.compressVideo, .videoToGIF, .extractAudio, .to(.mov)]
            } else {
                result += [.to(.mp4), .compressVideo, .videoToGIF, .extractAudio]
            }
        }
        if kinds.contains(.audio) {
            let onlyMP3 = extensions == ["mp3"]
            if onlyMP3 {
                result += [.to(.m4a), .to(.wav), .to(.flac)]
            } else {
                result += [.to(.mp3), .to(.m4a), .to(.flac), .to(.wav)]
            }
        }
        if kinds.contains(.data) {
            let onlyJSON = extensions == ["json"]
            let onlyCSV = extensions == ["csv"]
            if onlyJSON {
                result += [.to(.csv), .to(.xlsx), .to(.yaml)]
            } else if onlyCSV {
                result += [.to(.xlsx), .to(.json), .to(.tsv)]
            } else {
                result += [.to(.json), .to(.csv), .to(.xlsx)]
            }
        }
        if kinds.contains(.document) {
            let onlyMD = extensions == ["md"]
            if onlyMD {
                result += [.to(.html), .to(.text)]
            } else {
                result += [.to(.markdown), .to(.html), .to(.text)]
            }
        }
        return result
    }

    /// Cheap extension-based guess for UI suggestions; planning still uses Rust detection.
    static func kind(of url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["csv", "tsv", "json", "yaml", "yml", "toml", "xlsx"].contains(ext) { return .data }
        if ["docx", "pptx"].contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) else { return .unknown }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .unknown
    }
}
