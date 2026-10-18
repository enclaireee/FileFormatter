import FileFormatterCore
import ImageIO
import SwiftUI

/// How hard the Compress actions squeeze. One saved setting, shared by the popover panel,
/// the queue header and the Finder "Compress" service.
struct CompressSettings: Equatable {
    enum Strength: String, CaseIterable, Identifiable {
        case light, balanced, strong, target
        var id: Self { self }
        var title: String {
            switch self {
            case .light: "Light"
            case .balanced: "Balanced"
            case .strong: "Strong"
            case .target: "Target size"
            }
        }
    }

    var strength: Strength = .balanced
    var targetMB: Double = 10

    static let presetsMB: [Double] = [1, 5, 10, 20, 25]

    static var saved: CompressSettings {
        get {
            let defaults = UserDefaults.standard
            let mb = defaults.double(forKey: "compress.targetMB")
            return CompressSettings(
                strength: defaults.string(forKey: "compress.strength").flatMap(Strength.init) ?? .balanced,
                targetMB: mb > 0 ? mb : 10
            )
        }
        set {
            UserDefaults.standard.set(newValue.strength.rawValue, forKey: "compress.strength")
            UserDefaults.standard.set(newValue.targetMB, forKey: "compress.targetMB")
        }
    }

    var targetBytes: UInt64 { UInt64(max(targetMB, 0.1) * 1_000_000) }

    /// Index into the Light/Balanced/Strong tables; nil for Target size.
    private var level: Int? {
        switch strength {
        case .light: 0
        case .balanced: 1
        case .strong: 2
        case .target: nil
        }
    }

    private static let imageLevels: [(quality: Double, maxPixelSize: Int?)] = [(0.85, nil), (0.7, 2560), (0.5, 1600)]
    private static let videoRatios = [0.7, 0.45, 0.25]

    func job(for action: QuickAction, urls: [URL]) -> ConversionJob {
        var job = ConversionJob(label: action.title)
        job.suffix = AppSettings.suffix(AppSettings.compressSuffix)
        switch action {
        case .compressImage:
            // ponytail: one alpha image makes the whole batch WebP; split per file if mixed batches matter.
            job.targets.image = urls.contains(where: Self.hasAlpha) ? .webp : .jpeg
            job.preserveMetadata = false
            if let level {
                job.quality = Self.imageLevels[level].quality
                job.maxPixelSize = Self.imageLevels[level].maxPixelSize
            } else {
                job.imageTargetBytes = targetBytes
            }
        case .compressPDF:
            job.pdfMode = .compress
            if let level {
                job.quality = PDFTools.compressionLevels[level].quality
                job.maxPixelSize = PDFTools.compressionLevels[level].maxPixelSize
            } else {
                job.imageTargetBytes = targetBytes
            }
        case .compressVideo:
            job.targets.video = .mp4
            if let level {
                job.mediaTargetRatio = Self.videoRatios[level]
            } else {
                job.mediaTargetBytes = targetBytes
            }
        default:
            break
        }
        return job
    }

    static func hasAlpha(_ url: URL) -> Bool {
        guard QuickAction.kind(of: url) == .image,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    // MARK: Estimate

    struct Estimate: Equatable {
        var input: UInt64
        var output: UInt64
        /// Target size: the output is a ceiling, not a measurement.
        var atMost = false
    }

    /// Sizes for the files this action applies to. Levels on images and PDFs compress the
    /// first file into a temp folder and scale; video and Target size are arithmetic.
    // ponytail: one sample file; average two or three if mixed batches estimate badly.
    func estimate(for action: QuickAction, urls: [URL]) async -> Estimate? {
        let kind: FileKind = switch action {
        case .compressImage: .image
        case .compressPDF: .pdf
        default: .video
        }
        let files = urls.filter { QuickAction.kind(of: $0) == kind }
        let sizes = files.map { UInt64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let input = sizes.reduce(0, +)
        guard let first = files.first, input > 0 else { return nil }

        if strength == .target {
            return Estimate(input: input, output: sizes.reduce(0) { $0 + min($1, targetBytes) }, atMost: true)
        }
        if action == .compressVideo, let level {
            return Estimate(input: input, output: UInt64(Double(input) * Self.videoRatios[level]))
        }

        let job = job(for: action, urls: urls)
        let sample = await Task.detached(priority: .userInitiated) { () -> UInt64? in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ff-estimate-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let out = folder.appendingPathComponent("sample").appendingPathExtension(
                    kind == .pdf ? "pdf" : job.targets.image.fileExtension
                )
                if kind == .pdf {
                    do {
                        try PDFTools.compress(source: first, destination: out, quality: job.quality, maxPixelSize: job.maxPixelSize)
                    } catch ConversionError.notSmaller {
                        return nil
                    }
                } else {
                    let (image, _) = try ImageTools.load(first, maxPixelSize: job.maxPixelSize)
                    try ImageTools.encode(image: image, destination: out, target: job.targets.image,
                                          quality: job.quality, targetBytes: nil)
                }
                return UInt64((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            } catch {
                return nil
            }
        }.value
        guard !Task.isCancelled else { return nil }
        guard let sample, let firstSize = sizes.first, firstSize > 0 else {
            return Estimate(input: input, output: input)
        }
        return Estimate(input: input, output: UInt64(Double(input) * Double(sample) / Double(firstSize)))
    }
}

/// Shown in the popover when a Compress action is picked: strength, target size, live estimate.
struct CompressPanel: View {
    let action: QuickAction
    let urls: [URL]
    let back: () -> Void
    let run: (ConversionJob) -> Void

    @State private var settings = CompressSettings.saved
    @State private var estimate: CompressSettings.Estimate?
    @State private var estimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(action.title).font(.headline)

            Picker("Strength", selection: $settings.strength) {
                ForEach(CompressSettings.Strength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.strength == .target {
                Picker("Size", selection: $settings.targetMB) {
                    ForEach(CompressSettings.presetsMB, id: \.self) { mb in
                        Text(mb == 20 ? "Email" : "\(Int(mb)) MB").tag(mb)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Email is 20 MB, the usual attachment limit")
                HStack(spacing: 6) {
                    Text("Or exactly").foregroundStyle(.secondary)
                    TextField("MB", value: $settings.targetMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .accessibilityLabel("Target size in megabytes")
                    Text("MB per file").foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            estimateLine
                .frame(minHeight: 20, alignment: .leading)

            HStack {
                Button("Back", action: back)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Compress") {
                    CompressSettings.saved = settings
                    run(settings.job(for: action, urls: urls))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(settings.strength == .target && settings.targetMB <= 0)
            }
        }
        .task(id: settings) {
            estimating = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await settings.estimate(for: action, urls: urls)
            guard !Task.isCancelled else { return }
            estimate = result
            estimating = false
        }
    }

    @ViewBuilder private var estimateLine: some View {
        if estimating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Estimating…").foregroundStyle(.secondary)
            }
        } else if let estimate {
            let before = Self.format(estimate.input)
            if estimate.output >= estimate.input {
                Label("\(before): already small, little to gain", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                let saved = Int((1 - Double(estimate.output) / Double(estimate.input)) * 100)
                let after = (estimate.atMost ? "at most " : "~") + Self.format(estimate.output)
                Text("\(before) → \(after) (−\(saved)%)")
                    .font(.body.monospacedDigit())
            }
        }
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
