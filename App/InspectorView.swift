import FileFormatterCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel
    @AppStorage(AppSettings.hdBackground) private var hdBackground = true
    @State private var showMoreImageOptions = false

    @Environment(\.openSettings) private var openSettings

    private var usesQuality: Bool {
        (model.hasKind(.image) && model.imageTarget.supportsQuality)
            || (model.hasKind(.pdf) && model.pdfMode == .compress)
            || (model.hasKind(.pdf) && model.pdfMode == .pages && model.imageTarget.supportsQuality)
            || (model.hasKind(.audio) && model.audioTarget.supportsQuality)
            || (model.hasKind(.video) && model.videoTarget.supportsQuality)
    }

    private var hasCustomImageOptions: Bool {
        model.maxPixelSize != nil || model.imageTargetBytes != nil || !model.preserveMetadata
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

    var body: some View {
        Group {
            if model.isEmpty {
                empty
            } else {
                form
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }

    private var empty: some View {
        EmptyStatePanel(
            systemImage: "slider.horizontal.3",
            title: "Settings",
            message: "Add files to choose formats, quality, and where the results go. You can also start from a preset."
        ) {
            Button("Add Files…") {
                model.showImporter = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var form: some View {
        Form {
            if model.isRunning {
                Section {
                    Label("Settings are locked while files are converting.", systemImage: "lock.fill")
                        .font(Theme.Text.body)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Preset", selection: presetBinding) {
                    Text("Custom").tag("custom")
                    Divider()
                    ForEach(Preset.builtIn) { preset in
                        Label(preset.name, systemImage: preset.systemImage).tag(preset.id)
                    }
                }
            } header: {
                Label("Recipe", systemImage: "wand.and.stars")
            } footer: {
                note("Sets the formats and quality for every kind of file in the queue.")
            }

            if model.hasKind(.image) || model.hasKind(.pdf) {
                mediaSection
            }

            if model.hasKind(.document) {
                Section {
                    Picker("Documents become", selection: documentBinding) {
                        ForEach(ConversionTarget.documentTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                } header: {
                    Label("Documents", systemImage: "doc.text")
                } footer: {
                    note("Headings, lists, tables and images are kept. Shapes and charts are not.")
                }
            }

            if model.hasKind(.data) {
                Section {
                    Picker("Data becomes", selection: dataBinding) {
                        ForEach(ConversionTarget.dataTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                } header: {
                    Label("Data", systemImage: "tablecells")
                } footer: {
                    note("CSV and TSV use the first row as column names. JSON output is a list of objects.")
                }
            }

            if model.hasKind(.audio) {
                Section {
                    Picker("Audio becomes", selection: audioBinding) {
                        ForEach(ConversionTarget.audioTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                } header: {
                    Label("Audio", systemImage: "waveform")
                } footer: {
                    note("MP3, M4A, Opus and OGG are lossy. FLAC, WAV and AIFF keep the original samples.")
                }
            }

            if model.hasKind(.video) {
                Section {
                    Picker("Video becomes", selection: videoBinding) {
                        ForEach(ConversionTarget.videoTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                        Divider()
                        Text(ConversionTarget.gif.displayName).tag(ConversionTarget.gif)
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
                } header: {
                    Label("Video", systemImage: "film")
                } footer: {
                    note("H.264 uses the hardware encoder. WebM uses VP9. Subtitles are kept when the format allows.")
                }
            }

            if !unsupportedKinds.isEmpty {
                Section {
                    Label(
                        "Not convertible yet: \(unsupportedKinds.joined(separator: ", ")). They stay in the queue as skipped.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Palette.warning)
                } header: {
                    Label("Other files", systemImage: "questionmark.folder")
                }
            }

            if usesQuality {
                Section {
                    HStack(spacing: Theme.Space.sm) {
                        Slider(value: $model.quality, in: 0.3...1.0)
                        Text("\(Int(model.quality * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                } header: {
                    Label("Quality", systemImage: "slider.horizontal.3")
                } footer: {
                    note("Used by formats that support it. Lossless formats ignore this.")
                }
            }

            Section {
                LabeledContent("Save to") {
                    HStack(spacing: Theme.Space.sm) {
                        Text(model.destinationDescription)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { openSettings() }
                            .controlSize(.small)
                    }
                }

                TextField("Add to name", text: $model.suffix)
                    .onSubmit { model.scheduleReplan() }

                if let example = model.outputExample {
                    note("Example: \(example)")
                }
            } header: {
                Label("Output", systemImage: "folder")
            } footer: {
                note("Originals are never changed. A number is added if the name is already taken.")
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRunning)
        .onAppear {
            if hasCustomImageOptions { showMoreImageOptions = true }
        }
        .onChange(of: model.suffix) { _, _ in model.scheduleReplan() }
        .onChange(of: model.pdfMode) { _, _ in model.scheduleReplan() }
        .onChange(of: model.removeBackground) { _, _ in model.scheduleReplan() }
        .onChange(of: model.maxPixelSize) { _, _ in model.scheduleReplan() }
        .onChange(of: model.imageTargetBytes) { _, _ in model.scheduleReplan() }
        .onChange(of: model.videoTargetBytes) { _, _ in model.scheduleReplan() }
    }

    // MARK: Images and PDFs

    @ViewBuilder
    private var mediaSection: some View {
        Section {
            if model.hasKind(.pdf) {
                Picker("PDFs become", selection: $model.pdfMode) {
                    ForEach(PDFMode.conversionCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if model.pdfMode == .pages || model.hasKind(.image) {
                    Picker(
                        model.hasKind(.image) ? "Images and PDF pages" : "Page format",
                        selection: imageBinding
                    ) {
                        ForEach(ConversionTarget.imageTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                }

                note(pdfNote)
            } else if model.hasKind(.image) {
                Picker("Images become", selection: imageBinding) {
                    ForEach(ConversionTarget.imageTargets) { target in
                        Text(target.displayName).tag(target)
                    }
                }

                if model.imageTarget == .pdf {
                    note("Each image becomes a one-page PDF at its source pixel size.")
                } else if !model.imageTarget.supportsQuality {
                    note("Lossless output. Quality doesn't apply.")
                }
            }

            if model.hasKind(.image) {
                Toggle("Remove background", isOn: $model.removeBackground)

                if model.removeBackground && model.imageTarget == .jpeg {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Label("JPEG can't keep the transparent background.", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.Palette.warning)
                        Spacer(minLength: Theme.Space.sm)
                        Button("Use PNG") {
                            model.imageTarget = .png
                            model.scheduleReplan()
                        }
                        .controlSize(.small)
                    }
                }

                DisclosureGroup(isExpanded: $showMoreImageOptions) {
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
                } label: {
                    Text("More image options")
                }
            }
        } header: {
            Label(
                model.hasKind(.image) && model.hasKind(.pdf) ? "Images and PDFs" : model.hasKind(.pdf) ? "PDF" : "Images",
                systemImage: model.hasKind(.pdf) && !model.hasKind(.image) ? "doc.richtext" : "photo"
            )
        }
    }

    private var pdfNote: String {
        switch model.pdfMode {
        case .pages:
            return model.hasKind(.image)
                ? "Each PDF page becomes an image in the format above. Images use the same format."
                : "Each page becomes a separate image in the format above."
        case .searchable:
            return "Adds a selectable text layer with OCR. The result stays a PDF."
        case .split:
            return "Writes one PDF for each page."
        case .compress:
            return "Redraws images to make the file smaller. Text and vectors stay sharp."
        case .merge:
            return "Combines every PDF in the list into one document."
        case .tool, .text:
            return ""
        }
    }

    // MARK: Units

    private var unsupportedKinds: [String] {
        var seen = Set<String>()
        return model.items.compactMap { item in
            guard item.kind != .image, item.kind != .data,
                  item.kind != .pdf, item.kind != .document,
                  item.kind != .audio, item.kind != .video else { return nil }
            return seen.insert(item.kind.label).inserted ? item.kind.label : nil
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Bindings

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
}
