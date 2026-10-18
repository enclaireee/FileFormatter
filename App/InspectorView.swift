import FileFormatterCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel
    @AppStorage(AppSettings.hdBackground) private var hdBackground = true

    var body: some View {
        Form {
            if model.isEmpty || model.hasKind(.image) || model.hasKind(.pdf) {
                Section("Images") {
                    Picker("Convert to", selection: imageBinding) {
                        ForEach(ConversionTarget.imageTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    if model.imageTarget == .pdf {
                        Text("Each image becomes a one-page PDF. Pages keep the source pixel dimensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.imageTarget.supportsQuality {
                        LabeledContent("Quality") {
                            Text("\(Int(model.quality * 100))%")
                                .monospacedDigit()
                        }
                        Slider(value: $model.quality, in: 0.3...1.0)
                    } else {
                        Text("Lossless output · quality does not apply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Preserve metadata", isOn: $model.preserveMetadata)

                    Toggle("Remove background", isOn: $model.removeBackground)
                    Text(!hdBackground || AppSettings.bundledBackgroundModel == nil
                         ? "Cuts out the main subject with Apple Vision. Fails for files with no clear subject."
                         : "Cuts out the subject with the HD model. Change it in Settings. Fails for files with no clear subject.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.removeBackground && model.imageTarget == .jpeg {
                        Text("JPEG can't keep transparency. Choose PNG, WebP, or HEIC.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Picker("Resize", selection: $model.maxPixelSize) {
                        Text("Original").tag(Int?.none)
                        ForEach([3840, 2560, 1920, 1280, 800], id: \.self) { px in
                            Text("\(px) px").tag(Int?.some(px))
                        }
                    }
                    if model.imageTarget.supportsQuality {
                        Picker("Target size", selection: $model.imageTargetBytes) {
                            Text("None").tag(UInt64?.none)
                            Text("5 MB").tag(UInt64?.some(5_000_000))
                            Text("2 MB").tag(UInt64?.some(2_000_000))
                            Text("1 MB").tag(UInt64?.some(1_000_000))
                            Text("500 KB").tag(UInt64?.some(500_000))
                        }
                    }

                    if model.hasKind(.pdf) {
                        Picker("PDFs", selection: $model.pdfMode) {
                            ForEach(PDFMode.allCases) { Text($0.label).tag($0) }
                        }
                        Text(model.pdfMode != .pages
                             ? "\(model.pdfMode.label). The image target is ignored for PDFs."
                             : (model.imageTarget.family == .image
                                ? "PDF pages are rendered to this image format."
                                : "Choose an image format to extract PDF pages."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.hasKind(.data) {
                Section("Data") {
                    Picker("Convert to", selection: dataBinding) {
                        ForEach(ConversionTarget.dataTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    Text("CSV and TSV are read as a table with a header row. JSON output is an array of objects; JSON to CSV requires the same shape.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.hasKind(.document) {
                Section("Documents") {
                    Picker("Convert to", selection: documentBinding) {
                        ForEach(ConversionTarget.documentTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    Text("DOCX and PPTX keep headings, bold/italic, lists, tables, and images (images go to a <name>_files folder). Plain text stays text-only. Shapes and charts are not preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.hasKind(.audio) {
                Section("Audio") {
                    Picker("Convert to", selection: audioBinding) {
                        ForEach(ConversionTarget.audioTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    if model.audioTarget.supportsQuality {
                        LabeledContent("Quality") {
                            Text("\(Int(model.quality * 100))%")
                                .monospacedDigit()
                        }
                        Slider(value: $model.quality, in: 0.3...1.0)
                    }
                    Text("Audio tracks and metadata are written with FFmpeg. Lossless targets are FLAC, WAV, and AIFF.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.hasKind(.video) {
                Section("Video") {
                    Picker("Convert to", selection: videoBinding) {
                        ForEach(ConversionTarget.videoTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                        if !ConversionTarget.videoTargets.contains(.gif) {
                            Text(ConversionTarget.gif.displayName).tag(ConversionTarget.gif)
                        }
                        Divider()
                        Section("Audio only") {
                            ForEach(ConversionTarget.audioTargets) { target in
                                Text(target.displayName).tag(target)
                            }
                        }
                    }
                    if model.videoTarget.family == .video {
                        Picker("Compress to", selection: $model.videoTargetBytes) {
                            Text("Original quality").tag(UInt64?.none)
                            ForEach([10, 25, 50, 100], id: \.self) { mb in
                                Text("\(mb) MB").tag(UInt64?.some(UInt64(mb) * 1_000_000))
                            }
                        }
                    }
                    LabeledContent("Quality") {
                        Text("\(Int(model.quality * 100))%")
                            .monospacedDigit()
                    }
                    Slider(value: $model.quality, in: 0.3...1.0)
                    Text("H.264 uses the hardware encoder. WebM uses VP9/Opus. Subtitles are copied where the container supports them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !unsupportedKinds.isEmpty {
                Section("Other files") {
                    Text("Not convertible yet: \(unsupportedKinds.joined(separator: ", ")). They stay in the queue as skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                TextField("Suffix", text: $model.suffix)
                    .onSubmit { model.scheduleReplan() }
                LabeledContent("Destination", value: "Same folder")
            }

            Section("Plan") {
                if model.isPlanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Planning…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.isEmpty {
                    Text("Add files to see their conversion plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Files", value: "\(model.items.count)")
                    LabeledContent("Ready", value: "\(model.runnableCount)")
                    ForEach(FidelityLevel.allCases, id: \.self) { level in
                        let count = model.items.filter { $0.fidelity == level }.count
                        if count > 0 {
                            LabeledContent(level.label, value: "\(count)")
                        }
                    }
                }
            }

            Section {
                Text("Fidelity is predicted from the source and target. Lossless conversions preserve data; re-encoded files may lose detail or formatting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.suffix) { _, _ in
            model.scheduleReplan()
        }
        .onChange(of: model.pdfMode) { _, _ in
            model.scheduleReplan()
        }
        .onChange(of: model.removeBackground) { _, _ in model.scheduleReplan() }
        .onChange(of: model.maxPixelSize) { _, _ in model.scheduleReplan() }
        .onChange(of: model.imageTargetBytes) { _, _ in model.scheduleReplan() }
        .onChange(of: model.videoTargetBytes) { _, _ in model.scheduleReplan() }
    }

    private var imageBinding: Binding<ConversionTarget> {
        Binding(
            get: { model.imageTarget },
            set: { newValue in
                model.imageTarget = newValue
                model.scheduleReplan()
            }
        )
    }

    private var audioBinding: Binding<ConversionTarget> {
        Binding(
            get: { model.audioTarget },
            set: { newValue in
                model.audioTarget = newValue
                model.scheduleReplan()
            }
        )
    }

    private var videoBinding: Binding<ConversionTarget> {
        Binding(
            get: { model.videoTarget },
            set: { newValue in
                model.videoTarget = newValue
                model.scheduleReplan()
            }
        )
    }

    private var documentBinding: Binding<ConversionTarget> {
        Binding(
            get: { model.documentTarget },
            set: { newValue in
                model.documentTarget = newValue
                model.scheduleReplan()
            }
        )
    }

    private var dataBinding: Binding<ConversionTarget> {
        Binding(
            get: { model.dataTarget },
            set: { newValue in
                model.dataTarget = newValue
                model.scheduleReplan()
            }
        )
    }

    private var unsupportedKinds: [String] {
        var seen = Set<String>()
        return model.items.compactMap { item in
            guard item.kind != .image, item.kind != .data,
                  item.kind != .pdf, item.kind != .document,
                  item.kind != .audio, item.kind != .video else { return nil }
            return seen.insert(item.kind.label).inserted ? item.kind.label : nil
        }
    }
}
