import FileFormatterCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel

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

                    if model.hasKind(.pdf) {
                        Toggle("OCR PDFs into searchable PDFs", isOn: $model.ocrPDF)
                        Text(model.ocrPDF
                             ? "Each PDF becomes one searchable PDF. The image target is ignored for PDFs."
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
                    Text("DOCX and PPTX are extracted as text. Layout, styles, shapes, charts, and images are not preserved.")
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
        .onChange(of: model.ocrPDF) { _, _ in
            model.scheduleReplan()
        }
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
