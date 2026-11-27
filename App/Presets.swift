import FileFormatterCore
import Foundation

struct Preset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let systemImage: String
    let imageTarget: ConversionTarget
    let dataTarget: ConversionTarget
    let documentTarget: ConversionTarget
    let quality: Double
    let suffix: String
    let audioTarget: ConversionTarget
    let videoTarget: ConversionTarget
    let pdfMode: PDFMode
    let removeBackground: Bool

    init(
        id: String,
        name: String,
        subtitle: String = "",
        systemImage: String,
        imageTarget: ConversionTarget,
        dataTarget: ConversionTarget,
        documentTarget: ConversionTarget,
        quality: Double,
        suffix: String,
        audioTarget: ConversionTarget = .mp3,
        videoTarget: ConversionTarget = .mp4,
        pdfMode: PDFMode = .pages,
        removeBackground: Bool = false
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.imageTarget = imageTarget
        self.dataTarget = dataTarget
        self.documentTarget = documentTarget
        self.quality = quality
        self.suffix = suffix
        self.audioTarget = audioTarget
        self.videoTarget = videoTarget
        self.pdfMode = pdfMode
        self.removeBackground = removeBackground
    }

    var job: ConversionJob {
        ConversionJob(
            label: name,
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
            removeBackground: removeBackground
        )
    }
}

extension Preset {
    static let builtIn: [Preset] = [
        Preset(
            id: "web-images",
            name: "Web Images",
            subtitle: "WebP · Small & sharp",
            systemImage: "photo.on.rectangle.angled",
            imageTarget: .webp,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.82,
            suffix: "-web"
        ),
        Preset(
            id: "remove-bg",
            name: "Remove Background",
            subtitle: "Transparent PNG",
            systemImage: "person.crop.rectangle.badge.plus",
            imageTarget: .png,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 1.0,
            suffix: "-nobg",
            removeBackground: true
        ),
        Preset(
            id: "compress-pdf",
            name: "Compress PDF",
            subtitle: "Smaller file size",
            systemImage: "arrow.down.doc",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.75,
            suffix: "-small",
            pdfMode: .compress
        ),
        Preset(
            id: "images-pdf",
            name: "Images → PDF",
            subtitle: "1 PDF per image",
            systemImage: "doc.richtext",
            imageTarget: .pdf,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 1.0,
            suffix: "-pdf"
        ),
        Preset(
            id: "archive-photos",
            name: "Archive Photos",
            subtitle: "HEIC · High quality",
            systemImage: "archivebox",
            imageTarget: .heic,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.90,
            suffix: "-archive"
        ),
        Preset(
            id: "pdf-pages",
            name: "PDF → PNG Pages",
            subtitle: "Extract pages",
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
            subtitle: "Exact pixels",
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
            subtitle: "Clean objects",
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
            subtitle: "Excel workbook",
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
            subtitle: "M4A AAC",
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
            subtitle: "FLAC",
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
            subtitle: "Universal MP4",
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
            subtitle: "Web video",
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
            subtitle: "DOCX & PPTX",
            systemImage: "text.alignleft",
            imageTarget: .jpeg,
            dataTarget: .json,
            documentTarget: .markdown,
            quality: 0.85,
            suffix: "-md"
        )
    ]
}
