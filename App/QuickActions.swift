import FileFormatterCore
import Foundation
import UniformTypeIdentifiers

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
    /// Set per run from Settings; nil writes next to the source.
    var outputDirectory: URL?

    func target(for item: ConversionItem) -> ConversionTarget? {
        if item.kind == .pdf {
            if item.pdfMode == .searchable { return .searchablePDF }
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
            outputDirectory: outputDirectory
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

    /// Plain format conversions that make sense for the dropped kinds, for the "Other formats" menu.
    static func otherFormats(for urls: [URL]) -> [QuickAction] {
        let kinds = Set(urls.map(kind(of:)))
        var families: [FormatFamily] = []
        if kinds.contains(.image) || kinds.contains(.pdf) { families += [.image] }
        if kinds.contains(.video) { families += [.video, .audio] }
        if kinds.contains(.audio) { families += [.audio] }
        if kinds.contains(.data) { families += [.data] }
        if kinds.contains(.document) { families += [.document] }
        var result = ConversionTarget.allCases
            .filter { families.contains($0.family) && $0 != .searchablePDF && !($0 == .gif && !kinds.contains(.image)) }
            .map(QuickAction.to)
        if kinds.contains(.video) { result.append(.videoToGIF) }
        return result
    }

    private static func defaults(for urls: [URL]) -> [QuickAction] {
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        let kinds = Set(urls.map(kind(of:)))
        var result: [QuickAction] = []

        if kinds.contains(.image) {
            let allJPEG = extensions.isSubset(of: ["jpg", "jpeg"])
            result += [allJPEG ? .to(.png) : .to(.jpeg), .removeBackground, .compressImage, .makePDF]
            result += [allJPEG ? .to(.heic) : .to(.png), .to(.webp)]
        }
        if kinds.contains(.pdf) {
            let pdfCount = urls.filter { kind(of: $0) == .pdf }.count
            result += pdfCount > 1 ? [.makePDF, .compressPDF, .splitPDF] : [.compressPDF, .splitPDF]
            result += [.to(.png), .ocr]
        }
        if kinds.contains(.video) {
            result += [.to(.mp4), .videoToGIF, .extractAudio, .compressVideo]
        }
        if kinds.contains(.audio) {
            result += [.to(.mp3), .to(.m4a), .to(.wav)]
        }
        if kinds.contains(.data) {
            result += [.to(.json), .to(.csv), .to(.xlsx)]
        }
        if kinds.contains(.document) {
            result += [.to(.markdown), .to(.html), .to(.text)]
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
