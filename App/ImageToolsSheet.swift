import AppKit
import FileFormatterCore
import SwiftUI
import UniformTypeIdentifiers

/// Batch image edits: rotate, flip and crop to a ratio. Everything is applied before the file is re-encoded.
struct ImageToolsSheet: View {
    let model: AppModel
    @State private var urls: [URL]
    @State private var operation: Operation = .rotateRight
    @State private var cropAspect: CropAspect = .square
    @State private var customWidth = 4.0
    @State private var customHeight = 5.0
    @State private var anchorX = 0.5
    @State private var anchorY = 0.5
    @State private var suffix = "-rotated"
    @State private var preview: CGImage?
    @State private var previewFailed = false
    @State private var isRunning = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, urls: [URL]) {
        self.model = model
        _urls = State(initialValue: urls)
    }

    enum Operation: String, CaseIterable, Identifiable {
        case rotateLeft, rotateRight, rotate180, flipHorizontal, flipVertical, crop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rotateLeft: "Rotate Left"
            case .rotateRight: "Rotate Right"
            case .rotate180: "Rotate 180°"
            case .flipHorizontal: "Flip Horizontal"
            case .flipVertical: "Flip Vertical"
            case .crop: "Crop"
            }
        }

        var systemImage: String {
            switch self {
            case .rotateLeft: "rotate.left"
            case .rotateRight: "rotate.right"
            case .rotate180: "arrow.counterclockwise"
            case .flipHorizontal: "arrow.left.and.right"
            case .flipVertical: "arrow.up.and.down"
            case .crop: "crop"
            }
        }

        var suffix: String {
            switch self {
            case .rotateLeft, .rotateRight, .rotate180: "-rotated"
            case .flipHorizontal, .flipVertical: "-flipped"
            case .crop: "-cropped"
            }
        }
    }

    enum CropAspect: String, CaseIterable, Identifiable {
        case square, portrait, story, landscape, classic, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .square: "Square (1:1)"
            case .portrait: "Portrait (4:5)"
            case .story: "Story (9:16)"
            case .landscape: "Landscape (16:9)"
            case .classic: "Classic (3:2)"
            case .custom: "Custom"
            }
        }

        var ratio: Double? {
            switch self {
            case .square: 1
            case .portrait: 4.0 / 5
            case .story: 9.0 / 16
            case .landscape: 16.0 / 9
            case .classic: 3.0 / 2
            case .custom: nil
            }
        }
    }

    private var edit: ImageEdit {
        switch operation {
        case .rotateLeft: return ImageEdit(rotation: 270)
        case .rotateRight: return ImageEdit(rotation: 90)
        case .rotate180: return ImageEdit(rotation: 180)
        case .flipHorizontal: return ImageEdit(flip: .horizontal)
        case .flipVertical: return ImageEdit(flip: .vertical)
        case .crop:
            let aspect = cropAspect.ratio ?? (customHeight > 0 ? customWidth / customHeight : 1)
            return ImageEdit(crop: ImageCrop(aspect: aspect, anchorX: anchorX, anchorY: anchorY))
        }
    }

    private var canRun: Bool {
        !urls.isEmpty && !isRunning && !model.isBusy && (operation != .crop || customWidth > 0 && customHeight > 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolSheetHeader(
                title: "Image Tools",
                subtitle: "Rotate, flip or crop a batch. Every file keeps its original format.",
                systemImage: "crop.rotate",
                fileSummary: fileSummary,
                fileURL: urls.first,
                chooseTitle: "Choose Images…",
                isRunning: isRunning,
                choose: choose
            )
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.md)

            Hairline()

            HStack(alignment: .top, spacing: Theme.Space.xl) {
                ScrollView(.vertical, showsIndicators: false) {
                    controls
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 330)

                ToolPreviewPane(caption: previewCaption) {
                    previewContent
                }
                .frame(width: 330)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(Theme.Space.xl)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.warning)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.md)
            }

            Hairline()

            ToolSheetFooter(
                fileCount: urls.count,
                isRunning: isRunning,
                canApply: canRun,
                applyTitle: urls.isEmpty ? "Apply" : "Apply to \(urls.count)",
                cancel: { dismiss() },
                apply: run
            )
            .padding(Theme.Space.xl)
        }
        .frame(width: 740, height: 580)
        .interactiveDismissDisabled(isRunning)
        .dropDestination(for: URL.self) { dropped, _ in
            let images = dropped.filter { QuickAction.kind(of: $0) == .image }
            if images.count < dropped.count {
                error = "Only images can be edited here."
            }
            add(images)
            return true
        }
        .task(id: PreviewRequest(url: urls.first, edit: edit)) {
            await loadPreview()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Action")
                    .font(Theme.Text.sectionTitle)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(Operation.allCases) { item in
                        actionButton(item)
                    }
                }
                .controlSize(.small)
            }

            if operation == .crop {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Picker("Ratio", selection: $cropAspect) {
                        ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
                    }

                    if cropAspect == .custom {
                        HStack(spacing: 6) {
                            TextField("Width", value: $customWidth, format: .number)
                                .frame(width: 64)
                            Text(":")
                                .foregroundStyle(.secondary)
                            TextField("Height", value: $customHeight, format: .number)
                                .frame(width: 64)
                        }
                        .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top, spacing: Theme.Space.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Keep")
                                .font(Theme.Text.body)
                            Text("Choose which part of the frame survives.")
                                .font(Theme.Text.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Space.sm)
                        anchorGrid
                    }
                }
                .padding(Theme.Space.md)
                .background(
                    Theme.Palette.sunken.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: "Add to name", help: "The output is written next to the original with this ending.")
                TextField("Add to name", text: $suffix)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Text("Output is re-encoded in the original format. Animated GIFs are skipped.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isBusy {
                Label("Another conversion is running.", systemImage: "hourglass")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isRunning)
    }

    @ViewBuilder
    private func actionButton(_ item: Operation) -> some View {
        let button = Button {
            operation = item
            suffix = item.suffix
        } label: {
            Label(item.title, systemImage: item.systemImage)
                .font(Theme.Text.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .help(item.title)

        if operation == item {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var anchorGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { column in
                        let x = Double(column) / 2
                        let y = Double(row) / 2
                        Button {
                            anchorX = x
                            anchorY = y
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(anchorX == x && anchorY == y ? Theme.Palette.accent : Color.primary.opacity(0.08))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(
                                            anchorX == x && anchorY == y
                                                ? Theme.Palette.accent
                                                : Theme.Palette.hairline.opacity(0.7),
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(anchorLabel(x: x, y: y))
                        .accessibilityLabel(anchorLabel(x: x, y: y))
                        .accessibilityAddTraits(anchorX == x && anchorY == y ? .isSelected : [])
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Crop anchor")
    }

    private func anchorLabel(x: Double, y: Double) -> String {
        let horizontal = x == 0 ? "Left" : x == 1 ? "Right" : "Center"
        let vertical = y == 0 ? "top" : y == 1 ? "bottom" : "middle"
        return "\(horizontal) \(vertical)"
    }

    @ViewBuilder
    private var previewContent: some View {
        if let preview {
            Image(decorative: preview, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(10)
        } else if urls.isEmpty {
            Text("Choose images to see a preview.")
                .font(Theme.Text.body)
                .foregroundStyle(.secondary)
        } else if previewFailed {
            Label("No preview for this file.", systemImage: "photo.badge.exclamationmark")
                .font(Theme.Text.body)
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var previewCaption: String {
        guard let first = urls.first else { return "Preview" }
        return urls.count == 1
            ? "Preview · \(first.lastPathComponent)"
            : "Preview of \(first.lastPathComponent) · \(urls.count) images"
    }

    private var fileSummary: String {
        guard let first = urls.first else { return "No images selected" }
        return urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) and \(urls.count - 1) more"
    }

    private func add(_ new: [URL]) {
        var seen = Set(urls.map(\.path))
        urls += new.filter { seen.insert($0.path).inserted }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func loadPreview() async {
        previewFailed = false
        guard let url = urls.first else {
            preview = nil
            return
        }
        let edit = edit
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let loaded = try? ImageTools.load(url, maxPixelSize: 600),
                  let edited = try? ImageTools.apply(edit, to: loaded.image) else { return nil }
            return edited
        }.value
        guard !Task.isCancelled else { return }
        preview = image
        previewFailed = image == nil
    }

    private func run() {
        error = nil
        let job = ConversionJob(
            label: "Image Tools",
            suffix: suffix,
            quality: 0.92,
            preserveMetadata: true,
            imageEdit: edit
        )
        isRunning = true
        Task {
            let summary = await model.runTool(urls: urls, job: job)
            isRunning = false
            if let summary {
                if summary.converted > 0 {
                    dismiss()
                } else {
                    error = summary.failed > 0
                        ? "The edit failed. Open the file to check it isn't damaged."
                        : "Nothing was edited."
                }
            } else {
                error = "The tool could not run. Try again after the current conversion finishes."
            }
        }
    }

    private struct PreviewRequest: Equatable {
        let url: URL?
        let edit: ImageEdit
    }
}
