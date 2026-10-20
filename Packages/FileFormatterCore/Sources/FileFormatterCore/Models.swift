import CoreGraphics
import Foundation
import UniformTypeIdentifiers

public enum FormatFamily: String, Sendable, CaseIterable {
    case image
    case pdf
    case document
    case data
    case audio
    case video
    case other
}

public enum ConversionTarget: String, CaseIterable, Sendable, Identifiable, Codable, Hashable {
    case jpeg
    case png
    case heic
    case avif
    case webp
    case tiff
    case csv
    case tsv
    case json
    case yaml
    case toml
    case xlsx
    case pdf
    case markdown
    case text
    case html
    case searchablePDF
    case mp3
    case m4a
    case flac
    case wav
    case aiff
    case opus
    case ogg
    case mp4
    case mov
    case mkv
    case webm
    case gif

    public static let imageTargets: [ConversionTarget] = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .pdf]
    public static let dataTargets: [ConversionTarget] = [.csv, .tsv, .json, .yaml, .toml, .xlsx]
    public static let documentTargets: [ConversionTarget] = [.markdown, .text, .html]
    public static let audioTargets: [ConversionTarget] = [.mp3, .m4a, .flac, .wav, .aiff, .opus, .ogg]
    public static let videoTargets: [ConversionTarget] = [.mp4, .mov, .mkv, .webm]

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .xlsx: "XLSX"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .text: "Plain Text"
        case .html: "HTML"
        case .searchablePDF: "Searchable PDF"
        case .mp3: "MP3"
        case .m4a: "M4A (AAC)"
        case .flac: "FLAC"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .opus: "Opus"
        case .ogg: "OGG Vorbis"
        case .mp4: "MP4 (H.264)"
        case .mov: "QuickTime (H.264)"
        case .mkv: "MKV (H.264)"
        case .webm: "WebM (VP9)"
        case .gif: "GIF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .text: "txt"
        case .searchablePDF: "pdf"
        default: rawValue
        }
    }

    public var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .image
        case .webp: UTType("org.webmproject.webp") ?? .image
        case .tiff: .tiff
        case .csv: .commaSeparatedText
        case .tsv: UTType(filenameExtension: "tsv") ?? .tabSeparatedText
        case .json: .json
        case .yaml: UTType(filenameExtension: "yaml") ?? .data
        case .toml: UTType(filenameExtension: "toml") ?? .data
        case .xlsx: UTType(filenameExtension: "xlsx") ?? .data
        case .pdf: .pdf
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .text: .plainText
        case .html: .html
        case .searchablePDF: .pdf
        case .mp3: .mp3
        case .m4a: .mpeg4Audio
        case .flac: UTType(filenameExtension: "flac") ?? .audio
        case .wav: .wav
        case .aiff: .aiff
        case .opus: UTType(filenameExtension: "opus") ?? .audio
        case .ogg: UTType(filenameExtension: "ogg") ?? .audio
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .mkv: UTType(filenameExtension: "mkv") ?? .movie
        case .webm: UTType(filenameExtension: "webm") ?? .movie
        case .gif: .gif
        }
    }

    public var family: FormatFamily {
        switch self {
        case .jpeg, .png, .heic, .avif, .webp, .tiff, .gif: .image
        case .csv, .tsv, .json, .yaml, .toml, .xlsx: .data
        case .pdf: .pdf
        case .markdown, .text, .html, .searchablePDF: .document
        case .mp3, .m4a, .flac, .wav, .aiff, .opus, .ogg: .audio
        case .mp4, .mov, .mkv, .webm: .video
        }
    }

    public var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp, .mp3, .m4a, .opus, .ogg,
             .mp4, .mov, .mkv, .webm: true
        case .png, .tiff, .csv, .tsv, .json, .yaml, .toml, .xlsx, .pdf,
             .markdown, .text, .html, .searchablePDF, .flac, .wav, .aiff, .gif: false
        }
    }

    /// The image target that keeps a file's current format. Unknown image extensions fall back to PNG.
    public static func imageTarget(forExtension ext: String) -> ConversionTarget {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": .jpeg
        case "png": .png
        case "heic", "heif": .heic
        case "avif": .avif
        case "webp": .webp
        case "tif", "tiff": .tiff
        case "gif": .gif
        default: .png
        }
    }
}

public enum FidelityLevel: String, Sendable, Codable, CaseIterable {
    case lossless
    case reencode
    case lossy
    case extract
    case unsupported

    public var label: String {
        switch self {
        case .lossless: "Lossless"
        case .reencode: "Re-encode"
        case .lossy: "Lossy"
        case .extract: "Extract"
        case .unsupported: "Unsupported"
        }
    }

    public var explanation: String {
        switch self {
        case .lossless: "Pixels are preserved. The container or compression may change."
        case .reencode: "The image is re-encoded. Some generation loss is possible."
        case .lossy: "This conversion discards image data. Choose quality deliberately."
        case .extract: "This produces a new artifact from part of the source."
        case .unsupported: "This conversion is not supported yet."
        }
    }
}

public enum FileKind: String, Sendable, Codable, Hashable {
    case image
    case video
    case audio
    case pdf
    case document
    case data
    case archive
    case unknown

    public var label: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .document: "Document"
        case .data: "Data"
        case .archive: "Archive"
        case .unknown: "Unknown"
        }
    }
}

public enum ItemStatus: Sendable, Equatable {
    case pending
    case converting
    case completed
    case failed(String)
    case skipped(String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped: true
        case .pending, .converting: false
        }
    }
}

public struct ConversionItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sourceURL: URL
    public let displayName: String
    public let kind: FileKind
    public let byteSize: UInt64
    public var outputName: String
    public var fidelity: FidelityLevel
    public var note: String?
    public var status: ItemStatus
    public var outputURL: URL?
    public let pageIndex: Int?
    public let pageCount: Int?
    public let pdfMode: PDFMode
    /// Set for a merge item: every source, in order, combined into one PDF.
    public let mergeSources: [URL]?
    /// Explicit output target for tool runs, where each file keeps its own format.
    public let target: ConversionTarget?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        displayName: String,
        kind: FileKind,
        byteSize: UInt64,
        outputName: String,
        fidelity: FidelityLevel,
        note: String? = nil,
        status: ItemStatus = .pending,
        outputURL: URL? = nil,
        pageIndex: Int? = nil,
        pageCount: Int? = nil,
        pdfMode: PDFMode = .pages,
        mergeSources: [URL]? = nil,
        target: ConversionTarget? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.kind = kind
        self.byteSize = byteSize
        self.outputName = outputName
        self.fidelity = fidelity
        self.note = note
        self.status = status
        self.outputURL = outputURL
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.pdfMode = pdfMode
        self.mergeSources = mergeSources
        self.target = target
    }
}

public struct PlanResult: Sendable {
    public let items: [ConversionItem]
    public let warnings: [String]

    public init(items: [ConversionItem], warnings: [String]) {
        self.items = items
        self.warnings = warnings
    }
}

public struct TargetRecipe: Sendable {
    public var image: ConversionTarget
    public var data: ConversionTarget
    public var document: ConversionTarget
    public var audio: ConversionTarget
    public var video: ConversionTarget

    public init(
        image: ConversionTarget = .jpeg,
        data: ConversionTarget = .json,
        document: ConversionTarget = .markdown,
        audio: ConversionTarget = .mp3,
        video: ConversionTarget = .mp4
    ) {
        self.image = image
        self.data = data
        self.document = document
        self.audio = audio
        self.video = video
    }

    public func target(for kind: FileKind) -> ConversionTarget? {
        switch kind {
        case .image: image
        case .data: data
        case .document: document
        case .audio: audio
        case .video: video
        default: nil
        }
    }
}

/// What happens to PDFs in a plan.
public enum PDFMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case pages
    case searchable
    case split
    case compress
    case merge
    case tool
    case text

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pages: "Pages to images"
        case .searchable: "Make searchable (OCR)"
        case .split: "Split into pages"
        case .compress: "Compress"
        case .merge: "Merge into one PDF"
        case .tool: "Edit PDF"
        case .text: "Extract text"
        }
    }

    /// Modes the ordinary Convert button can run. `.tool` and `.text` need options from the Tools sheet.
    public static let conversionCases: [PDFMode] = [.pages, .searchable, .split, .compress, .merge]
}

public enum PDFPageSize: String, Sendable, Codable, CaseIterable, Identifiable {
    case a4
    case letter
    case legal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .a4: "A4"
        case .letter: "US Letter"
        case .legal: "US Legal"
        }
    }

    /// Points at 72 dpi.
    public var size: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        }
    }
}

/// One PDF tool operation. A single struct keeps planning and the queue simple: the kind picks the fields in use.
public struct PDFToolRequest: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable, Identifiable {
        case rotate
        case organize
        case pageSize
        case stamp
        case protect
        case unlock
        case text

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .rotate: "Rotate pages"
            case .organize: "Reorder or remove pages"
            case .pageSize: "Change page size"
            case .stamp: "Page numbers and watermark"
            case .protect: "Add a password"
            case .unlock: "Remove a password"
            case .text: "Extract text"
            }
        }
    }

    public var kind: Kind
    /// Clockwise degrees added to every page (rotate).
    public var rotation = 90
    /// 1-based page order; empty means every page in its current order.
    public var pageOrder: [Int] = []
    /// 1-based pages removed before ordering.
    public var deletePages: [Int] = []
    public var reversePages = false
    public var pageSize: PDFPageSize = .a4
    public var pageNumbers = true
    public var watermark = ""
    /// New password for `.protect`, current password for `.unlock` and for opening a locked source.
    public var password = ""
    /// Password of an already-locked source when `.protect` adds a new password.
    public var sourcePassword = ""
    public var textTarget: ConversionTarget = .markdown

    public init(kind: Kind) {
        self.kind = kind
    }

    public var fidelity: FidelityLevel {
        switch kind {
        case .rotate, .organize, .protect, .unlock: .lossless
        case .pageSize, .stamp: .reencode
        case .text: .extract
        }
    }

    /// File-name ending for the tool, so a batch never overwrites its sources.
    public var suffix: String {
        switch kind {
        case .rotate: "-rotated"
        case .organize: "-organized"
        case .pageSize: "-\(pageSize.rawValue)"
        case .stamp: "-stamped"
        case .protect: "-protected"
        case .unlock: "-unlocked"
        case .text: ""
        }
    }
}

public enum ImageFlip: String, Sendable, Codable, CaseIterable, Identifiable {
    case none
    case horizontal
    case vertical

    public var id: String { rawValue }
}

/// A crop expressed as an aspect ratio plus an anchor, so one recipe works across a mixed batch.
public struct ImageCrop: Sendable, Equatable, Codable {
    /// Width ÷ height. Nil keeps the original framing.
    public var aspect: Double?
    /// 0 = leading/top, 1 = trailing/bottom, 0.5 = centered.
    public var anchorX: Double = 0.5
    public var anchorY: Double = 0.5

    public init(aspect: Double?, anchorX: Double = 0.5, anchorY: Double = 0.5) {
        self.aspect = aspect
        self.anchorX = anchorX
        self.anchorY = anchorY
    }
}

/// Non-destructive edits applied before an image is encoded. Order: crop, rotate, flip.
public struct ImageEdit: Sendable, Equatable, Codable {
    /// Clockwise degrees: 0, 90, 180, 270.
    public var rotation: Int = 0
    public var flip: ImageFlip = .none
    public var crop: ImageCrop?

    public init(rotation: Int = 0, flip: ImageFlip = .none, crop: ImageCrop? = nil) {
        self.rotation = rotation
        self.flip = flip
        self.crop = crop
    }

    public var isIdentity: Bool {
        rotation % 360 == 0 && flip == .none && crop?.aspect == nil
    }

    public var suffix: String {
        if crop?.aspect != nil { return "-cropped" }
        if flip != .none { return "-flipped" }
        if rotation % 360 != 0 { return "-rotated" }
        return "-edited"
    }
}

public struct ConversionOptions: Sendable {
    public var target: ConversionTarget
    public var quality: Double
    public var suffix: String
    public var preserveMetadata: Bool
    public var maxPixelSize: Int?
    public var targetBytes: UInt64?
    public var removeBackground: Bool
    /// Compiled BiRefNet-lite for HD background removal; nil uses Vision.
    public var backgroundModel: URL?
    /// Crop, rotate and flip before encoding (image tools).
    public var imageEdit: ImageEdit?
    /// One PDF tool operation (PDF tools).
    public var pdfTool: PDFToolRequest?
    /// Where outputs go; nil writes next to the source.
    public var outputDirectory: URL?

    public init(
        target: ConversionTarget,
        quality: Double,
        suffix: String,
        preserveMetadata: Bool,
        maxPixelSize: Int? = nil,
        targetBytes: UInt64? = nil,
        removeBackground: Bool = false,
        backgroundModel: URL? = nil,
        imageEdit: ImageEdit? = nil,
        pdfTool: PDFToolRequest? = nil,
        outputDirectory: URL? = nil
    ) {
        self.target = target
        self.quality = quality
        self.suffix = suffix
        self.preserveMetadata = preserveMetadata
        self.maxPixelSize = maxPixelSize
        self.targetBytes = targetBytes
        self.removeBackground = removeBackground
        self.backgroundModel = backgroundModel
        self.imageEdit = imageEdit
        self.pdfTool = pdfTool
        self.outputDirectory = outputDirectory
    }
}

public struct RunSummary: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let target: String
    public let outputs: [URL]
    public let converted: Int
    public let skipped: Int
    public let failed: Int
    public let inputBytes: UInt64
    public let outputBytes: UInt64
    public var undone: Bool
    /// Batch renames as [from, to] pairs; undo moves them back. Nil for conversions.
    public var renames: [[URL]]?
    /// Inode of each output when it was written, parallel to `outputs`. Undo only trashes files that still match.
    /// Nil in journals written before 0.6.0.
    public var fileNumbers: [Int?]?

    /// The file's inode, read uncached.
    public static func fileNumber(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? Int
    }

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        target: String,
        outputs: [URL],
        converted: Int,
        skipped: Int,
        failed: Int,
        inputBytes: UInt64,
        outputBytes: UInt64,
        undone: Bool = false,
        renames: [[URL]]? = nil,
        fileNumbers: [Int?]? = nil
    ) {
        self.id = id
        self.date = date
        self.target = target
        self.outputs = outputs
        self.converted = converted
        self.skipped = skipped
        self.failed = failed
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.undone = undone
        self.fileNumbers = fileNumbers
        self.renames = renames
    }

    public var bytesSaved: Int64 { Int64(inputBytes) - Int64(outputBytes) }
}
