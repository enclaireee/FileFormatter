import FileFormatterCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel
    @AppStorage(AppSettings.hdBackground) private var hdBackground = true

    @Environment(\.openSettings) private var openSettings

    private var usesQuality: Bool {
        (model.hasKind(.image) && model.imageTarget.supportsQuality)
            || (model.hasKind(.audio) && model.audioTarget.supportsQuality)
            || model.hasKind(.video)
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { model.activePreset?.id ?? "custom" },
            set: { id in
                if let preset = Preset.builtIn.first(where: { $0.id == id }) {
                    model.apply(preset)
                }
            }
        )
    }

    private func percentLabel(_ title: String) -> some View {
        LabeledContent(title) {
            Text("\(Int(model.quality * 100))%").monospacedDigit()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    var body: some View {
        Form {
            Section("Preset") {
                Picker("Preset", selection: presetBinding) {
                    Text("Custom").tag("custom")
                    Divider()
                    ForEach(Preset.builtIn) { preset in
                        Label(preset.name, systemImage: preset.systemImage).tag(preset.id)
                    }
                }
                caption("Sets formats and quality for every file type.")
            }

            if model.isEmpty {
                Section {
                    caption("Add files to see their options.")
                }
            }

            if model.hasKind(.image) || model.hasKind(.pdf) {
                Section(model.hasKind(.pdf) ? "Images and PDFs" : "Images") {
                    Picker("Convert to", selection: imageBinding) {
                        ForEach(ConversionTarget.imageTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    if model.imageTarget == .pdf {
                        caption("Each image becomes a one-page PDF. Pages keep the source pixel dimensions.")
                    } else if !model.imageTarget.supportsQuality {
                        caption("Lossless output. Quality does not apply.")
                    }
                    Toggle("Keep photo info (location, camera)", isOn: $model.preserveMetadata)

                    Picker("Resize", selection: $model.maxPixelSize) {
                        Text("Original").tag(Int?.none)
                        ForEach([3840, 2560, 1920, 1280, 800], id: \.self) { px in
                            Text("\(px) px").tag(Int?.some(px))
                        }
                    }
                    if model.imageTarget.supportsQuality {
                        Picker("Target file size", selection: $model.imageTargetBytes) {
                            Text("None").tag(UInt64?.none)
                            Text("5 MB").tag(UInt64?.some(5_000_000))
                            Text("2 MB").tag(UInt64?.some(2_000_000))
                            Text("1 MB").tag(UInt64?.some(1_000_000))
                            Text("500 KB").tag(UInt64?.some(500_000))
                        }
                    }

                    Toggle("Remove background", isOn: $model.removeBackground)
                    caption(!hdBackground || AppSettings.bundledBackgroundModel == nil
                            ? "Cuts out the main subject with Apple Vision. Fails for files with no clear subject."
                            : "Cuts out the subject with the HD model. Change it in Settings. Fails for files with no clear subject.")
                    if model.removeBackground && model.imageTarget == .jpeg {
                        HStack {
                            Label("JPEG can't keep the transparent background.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Use PNG") {
                                model.imageTarget = .png
                                model.scheduleReplan()
                            }
                        }
                    }

                    if model.hasKind(.pdf) {
                        Picker("PDF pages become", selection: $model.pdfMode) {
                            ForEach(PDFMode.allCases) { Text($0.label).tag($0) }
                        }
                        caption(model.pdfMode != .pages
                                ? "\(model.pdfMode.label). The image format is ignored for PDFs."
                                : (model.imageTarget.family == .image
                                   ? "PDF pages are saved in this image format."
                                   : "Choose an image format to extract PDF pages."))
                        if model.pdfMode == .pages && model.imageTarget.family != .image {
                            Button("Use PNG for Pages") {
                                model.imageTarget = .png
                                model.scheduleReplan()
                            }
                        }
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
                    caption("CSV and TSV are read as a table with a header row. JSON output is an array of objects; JSON to CSV requires the same shape.")
                }
            }

            if model.hasKind(.document) {
                Section("Documents") {
                    Picker("Convert to", selection: documentBinding) {
                        ForEach(ConversionTarget.documentTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    caption("DOCX and PPTX keep headings, bold/italic, lists, tables, and images (images go to a <name>_files folder). Plain text stays text-only. Shapes and charts are not preserved.")
                }
            }

            if model.hasKind(.audio) {
                Section("Audio") {
                    Picker("Convert to", selection: audioBinding) {
                        ForEach(ConversionTarget.audioTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    caption("Audio tracks and metadata are written with FFmpeg. Lossless targets are FLAC, WAV, and AIFF.")
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
                    caption("H.264 uses the hardware encoder. WebM uses VP9/Opus. Subtitles are copied where the container supports them.")
                }
            }

            if !unsupportedKinds.isEmpty {
                Section("Other files") {
                    caption("Not convertible yet: \(unsupportedKinds.joined(separator: ", ")). They stay in the queue as skipped.")
                }
            }

            if usesQuality {
                Section("Quality") {
                    percentLabel("Quality")
                    Slider(value: $model.quality, in: 0.3...1.0)
                }
            }

            Section("Output") {
                LabeledContent("Saved") {
                    HStack {
                        Text(model.destinationDescription)
                        Button("Change…") { openSettings() }
                    }
                }
                TextField("Add to name", text: $model.suffix)
                    .onSubmit { model.scheduleReplan() }
                if let example = model.outputExample {
                    caption("Example: \(example)")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRunning)
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
