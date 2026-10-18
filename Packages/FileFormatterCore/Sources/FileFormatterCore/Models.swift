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
    case pdf

    public static let imageTargets: [ConversionTarget] = [.jpeg, .png, .heic, .avif, .webp, .tiff, .pdf]
    public static let dataTargets: [ConversionTarget] = [.csv, .tsv, .json, .yaml, .toml]

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
        case .pdf: "PDF"
        }
    }

    public var fileExtension: String { rawValue }

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
        case .pdf: .pdf
        }
    }

    public var family: FormatFamily {
        switch self {
        case .jpeg, .png, .heic, .avif, .webp, .tiff: .image
        case .csv, .tsv, .json, .yaml, .toml: .data
        case .pdf: .pdf
        }
    }

    public var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp: true
        case .png, .tiff, .csv, .tsv, .json, .yaml, .toml, .pdf: false
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
        outputURL: URL? = nil
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

    public init(image: ConversionTarget = .jpeg, data: ConversionTarget = .json) {
        self.image = image
        self.data = data
    }

    public func target(for kind: FileKind) -> ConversionTarget? {
        switch kind {
        case .image: image
        case .data: data
        default: nil
        }
    }
}

public struct ConversionOptions: Sendable {
    public var target: ConversionTarget
    public var quality: Double
    public var suffix: String
    public var preserveMetadata: Bool

    public init(
        target: ConversionTarget,
        quality: Double,
        suffix: String,
        preserveMetadata: Bool
    ) {
        self.target = target
        self.quality = quality
        self.suffix = suffix
        self.preserveMetadata = preserveMetadata
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
        undone: Bool = false
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
    }

    public var bytesSaved: Int64 { Int64(inputBytes) - Int64(outputBytes) }
}
