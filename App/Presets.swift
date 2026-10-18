import FileFormatterCore
import Foundation

struct Preset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let systemImage: String
    let imageTarget: ConversionTarget
    let dataTarget: ConversionTarget
    let documentTarget: ConversionTarget
    let quality: Double
    let suffix: String
    let audioTarget: ConversionTarget
    let videoTarget: ConversionTarget

    init(
        id: String,
        name: String,
        systemImage: String,
        imageTarget: ConversionTarget,
        dataTarget: ConversionTarget,
        documentTarget: ConversionTarget,
        quality: Double,
        suffix: String,
        audioTarget: ConversionTarget = .mp3,
        videoTarget: ConversionTarget = .mp4
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.imageTarget = imageTarget
        self.dataTarget = dataTarget
        self.documentTarget = documentTarget
        self.quality = quality
        self.suffix = suffix
        self.audioTarget = audioTarget
        self.videoTarget = videoTarget
    }
}

extension Preset {
    static let builtIn: [Preset] = [
        Preset(
            id: "web-images",
            name: "Web Images",
            systemImage: "photo.on.rectangle.angled",
            imageTarget: .webp,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.82,
            suffix: "-web"
        ),
        Preset(
            id: "archive-photos",
            name: "Archive Photos",
            systemImage: "archivebox",
            imageTarget: .heic,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.90,
            suffix: "-archive"
        ),
        Preset(
            id: "images-pdf",
            name: "Images → PDF",
            systemImage: "doc.richtext",
            imageTarget: .pdf,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 1.0,
            suffix: "-pdf"
        ),
        Preset(
            id: "pdf-pages",
            name: "PDF → PNG Pages",
            systemImage: "doc.text.image",
            imageTarget: .png,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 1.0,
            suffix: ""
        ),
        Preset(
            id: "lossless-png",
            name: "Lossless PNG",
            systemImage: "checkmark.seal",
            imageTarget: .png,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 1.0,
            suffix: "-png"
        ),
        Preset(
            id: "data-json",
            name: "Data → JSON",
            systemImage: "curlybraces",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.85,
            suffix: "-json"
        ),
        Preset(
            id: "data-xlsx",
            name: "Data → XLSX",
            systemImage: "tablecells",
            imageTarget: .jpeg,
            dataTarget: .xlsx,
            documentTarget: .markdown,
            quality: 0.85,
            suffix: "-xlsx"
        ),
        Preset(
            id: "audio-m4a",
            name: "Audio for iPhone",
            systemImage: "waveform",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.80,
            suffix: "-audio",
            audioTarget: .m4a
        ),
        Preset(
            id: "audio-flac",
            name: "Lossless Audio",
            systemImage: "waveform.badge.checkmark",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 1.0,
            suffix: "-lossless",
            audioTarget: .flac
        ),
        Preset(
            id: "video-mp4",
            name: "Video H.264",
            systemImage: "film",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.80,
            suffix: "-h264",
            videoTarget: .mp4
        ),
        Preset(
            id: "video-webm",
            name: "WebM VP9",
            systemImage: "film.stack",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.70,
            suffix: "-webm",
            videoTarget: .webm
        ),
        Preset(
            id: "office-markdown",
            name: "Office → Markdown",
            systemImage: "text.alignleft",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.85,
            suffix: "-md"
        )
    ]
}
