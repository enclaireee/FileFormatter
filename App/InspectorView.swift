import AppKit
import FileFormatterCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel
    @AppStorage(AppSettings.useFolder) private var useFolder = false
    @State private var showFineTuning = false

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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                recipeCard

                if model.hasKind(.image) {
                    imageCard
                }

                if model.hasKind(.pdf) {
                    pdfCard
                }

                if model.hasKind(.video) {
                    videoCard
                }

                if model.hasKind(.audio) {
                    audioCard
                }

                if model.hasKind(.data) {
                    dataCard
                }

                if model.hasKind(.document) {
                    documentCard
                }

                if usesQuality {
                    qualityCard
                }

                outputCard

                if !unsupportedKinds.isEmpty {
                    Label(
                        "Unsupported here: \(unsupportedKinds.joined(separator: ", ")). Those files are skipped safely.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Palette.warning)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.canvas)
        .disabled(model.isRunning)
        .opacity(model.isRunning ? 0.65 : 1)
        .onAppear {
            if hasCustomImageOptions { showFineTuning = true }
        }
        .onChange(of: model.suffix) { _, _ in model.scheduleReplan() }
        .onChange(of: model.pdfMode) { _, _ in model.scheduleReplan() }
        .onChange(of: model.removeBackground) { _, _ in model.scheduleReplan() }
        .onChange(of: model.maxPixelSize) { _, _ in model.scheduleReplan() }
        .onChange(of: model.imageTargetBytes) { _, _ in model.scheduleReplan() }
        .onChange(of: model.videoTargetBytes) { _, _ in model.scheduleReplan() }
    }

    // MARK: Sections

    private var recipeCard: some View {
        inspectorSection("Quick Recipe", systemImage: "wand.and.stars") {
            Picker("Preset", selection: presetBinding) {
                Text("Custom").tag("custom")
                Divider()
                ForEach(Preset.builtIn) { preset in
                    Label(preset.name, systemImage: preset.systemImage).tag(preset.id)
                }
            }
            .labelsHidden()
        }
    }

    private var imageCard: some View {
        let commonTargets: [ConversionTarget] = [.jpeg, .png, .webp, .heic, .avif, .pdf]
        let extraTargets: [ConversionTarget] = [.tiff, .gif]

        return inspectorSection("Images → Format", systemImage: "photo") {
            FlowLayout(spacing: 6) {
                ForEach(commonTargets) { target in
                    formatPill(
                        title: shortLabel(for: target),
                        selected: model.imageTarget == target
                    ) {
                        model.imageTarget = target
                        model.scheduleReplan()
                    }
                }
                Menu {
                    ForEach(extraTargets) { target in
                        Button(target.displayName) {
                            model.imageTarget = target
                            model.scheduleReplan()
                        }
                    }
                } label: {
                    Text(extraTargets.contains(model.imageTarget) ? model.imageTarget.displayName : "More…")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }

            Toggle("Remove background (transparent cutout)", isOn: Binding(
                get: { model.removeBackground },
                set: { on in
                    model.removeBackground = on
                    if on && model.imageTarget == .jpeg {
                        model.imageTarget = .png
                    }
                }
            ))
            .font(Theme.Text.body)
            .padding(.top, 2)

            DisclosureGroup(isExpanded: $showFineTuning) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Resize") {
                        Picker("", selection: $model.maxPixelSize) {
                            Text("Original").tag(Int?.none)
                            ForEach([3840, 2560, 1920, 1280, 800], id: \.self) { px in
                                Text("≤ \(px) px").tag(Int?.some(px))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    .font(Theme.Text.caption)

                    if model.imageTarget.supportsQuality {
                        LabeledContent("Max file size") {
                            Picker("", selection: $model.imageTargetBytes) {
                                Text("No limit").tag(UInt64?.none)
                                Text("5 MB").tag(UInt64?.some(5_000_000))
                                Text("2 MB").tag(UInt64?.some(2_000_000))
                                Text("1 MB").tag(UInt64?.some(1_000_000))
                                Text("500 KB").tag(UInt64?.some(500_000))
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }
                        .font(Theme.Text.caption)
                    }

                    Toggle("Keep camera & location EXIF", isOn: $model.preserveMetadata)
                        .font(Theme.Text.caption)
                }
                .padding(.top, 6)
            } label: {
                Text("Resize, size cap & metadata")
                    .font(Theme.Text.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pdfCard: some View {
        inspectorSection("PDF Action", systemImage: "doc.richtext") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Action", selection: $model.pdfMode) {
                    ForEach(PDFMode.conversionCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()

                if model.pdfMode == .pages && !model.hasKind(.image) {
                    FlowLayout(spacing: 6) {
                        ForEach([ConversionTarget.png, .jpeg, .webp, .tiff]) { target in
                            formatPill(title: shortLabel(for: target), selected: model.imageTarget == target) {
                                model.imageTarget = target
                                model.scheduleReplan()
                            }
                        }
                    }
                }

                note(pdfNote)
            }
        }
    }

    private var videoCard: some View {
        inspectorSection("Video → Format", systemImage: "film") {
            FlowLayout(spacing: 6) {
                ForEach([ConversionTarget.mp4, .mov, .mkv, .webm, .gif]) { target in
                    formatPill(title: shortLabel(for: target), selected: model.videoTarget == target) {
                        model.videoTarget = target
                        model.scheduleReplan()
                    }
                }
                Menu {
                    ForEach(ConversionTarget.audioTargets) { target in
                        Button("Audio: \(target.displayName)") {
                            model.videoTarget = target
                            model.scheduleReplan()
                        }
                    }
                } label: {
                    Text(model.videoTarget.family == .audio ? "Audio: \(shortLabel(for: model.videoTarget))" : "Audio only…")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }

            if model.videoTarget.family == .video {
                LabeledContent("Size limit") {
                    Picker("", selection: $model.videoTargetBytes) {
                        Text("None").tag(UInt64?.none)
                        ForEach([10, 25, 50, 100], id: \.self) { mb in
                            Text("≤ \(mb) MB").tag(UInt64?.some(UInt64(mb) * 1_000_000))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                .font(Theme.Text.caption)
            }

            note("Compatible streams remux instantly without quality loss.")
        }
    }

    private var audioCard: some View {
        inspectorSection("Audio → Format", systemImage: "waveform") {
            FlowLayout(spacing: 6) {
                ForEach(ConversionTarget.audioTargets) { target in
                    formatPill(title: shortLabel(for: target), selected: model.audioTarget == target) {
                        model.audioTarget = target
                        model.scheduleReplan()
                    }
                }
            }
        }
    }

    private var dataCard: some View {
        inspectorSection("Data → Format", systemImage: "tablecells") {
            FlowLayout(spacing: 6) {
                ForEach(ConversionTarget.dataTargets) { target in
                    formatPill(title: shortLabel(for: target), selected: model.dataTarget == target) {
                        model.dataTarget = target
                        model.scheduleReplan()
                    }
                }
            }
        }
    }

    private var documentCard: some View {
        inspectorSection("Documents → Format", systemImage: "doc.text") {
            FlowLayout(spacing: 6) {
                ForEach(ConversionTarget.documentTargets) { target in
                    formatPill(title: shortLabel(for: target), selected: model.documentTarget == target) {
                        model.documentTarget = target
                        model.scheduleReplan()
                    }
                }
            }
        }
    }

    private var qualityCard: some View {
        inspectorSection("Quality", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Theme.Space.sm) {
                    Slider(value: $model.quality, in: 0.3...1.0)
                    Text("\(Int((model.quality * 100).rounded()))%")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: 42, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    ForEach([("Smaller", 0.65), ("Balanced", 0.85), ("Best", 0.95)], id: \.0) { label, val in
                        Button(label) {
                            model.quality = val
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    private var outputCard: some View {
        inspectorSection("Where & Naming", systemImage: "folder") {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    Button {
                        useFolder = false
                    } label: {
                        if !useFolder { Label("Next to originals", systemImage: "checkmark") }
                        else { Text("Next to originals") }
                    }
                    Button("Choose Output Folder…") {
                        model.chooseOutputFolderInteractively()
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(model.destinationDescription)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("Change")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Suffix")
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                        TextField("none (e.g. -web)", text: $model.suffix)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit { model.scheduleReplan() }
                    }
                    HStack(spacing: 5) {
                        ForEach([("None", ""), ("-web", "-web"), ("-small", "-small"), ("-copy", "-copy")], id: \.0) { title, value in
                            Button(title) {
                                model.suffix = value
                                model.scheduleReplan()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }

                if let example = model.outputExample {
                    Text(example)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: Building blocks

    private func inspectorSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.Palette.surface.opacity(0.65),
            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.Palette.hairline.opacity(0.45), lineWidth: 1)
        }
    }

    private func formatPill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selected ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Color.primary.opacity(0.055)),
                    in: Capsule()
                )
                .overlay {
                    if !selected {
                        Capsule()
                            .strokeBorder(Theme.Palette.hairline.opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shortLabel(for target: ConversionTarget) -> String {
        switch target {
        case .m4a: "M4A"
        case .ogg: "OGG"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .mkv: "MKV"
        case .webm: "WebM"
        case .text: "TXT"
        default: target.displayName
        }
    }

    private var pdfNote: String {
        switch model.pdfMode {
        case .pages:
            return "Each page becomes an image."
        case .searchable:
            return "Embeds an invisible selectable OCR text layer."
        case .split:
            return "Saves one separate PDF per page."
        case .compress:
            return "Shrinks embedded images while keeping vector text sharp."
        case .merge:
            return "Combines every PDF in the queue into one file."
        case .tool, .text:
            return ""
        }
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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
