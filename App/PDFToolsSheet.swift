import AppKit
import FileFormatterCore
import PDFKit
import SwiftUI

/// The PDF toolkit: rotate, reorder, change page size, stamp, protect, unlock, or extract text.
struct PDFToolsSheet: View {
    let model: AppModel
    @State private var urls: [URL]
    @State private var kind: PDFToolRequest.Kind = .rotate
    @State private var rotation = 90
    @State private var orderText = ""
    @State private var deleteText = ""
    @State private var reversePages = false
    @State private var pageSize: PDFPageSize = .a4
    @State private var pageNumbers = true
    @State private var watermark = ""
    @State private var password = ""
    @State private var sourcePassword = ""
    @State private var textTarget: ConversionTarget = .markdown
    @State private var suffix = "-rotated"
    @State private var pageCount: Int?
    @State private var isLocked = false
    @State private var previewFailed = false
    @State private var thumbnail: NSImage?
    @State private var isRunning = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, urls: [URL]) {
        self.model = model
        _urls = State(initialValue: urls)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolSheetHeader(
                title: "PDF Tools",
                subtitle: "Rotate, organize, stamp, protect or extract text. Originals stay untouched.",
                systemImage: "doc.richtext",
                fileSummary: fileSummary,
                fileURL: urls.first,
                chooseTitle: "Choose PDFs…",
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
                .frame(width: 340)

                ToolPreviewPane(caption: pageLine) {
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
        .frame(width: 760, height: 600)
        .interactiveDismissDisabled(isRunning)
        .dropDestination(for: URL.self) { dropped, _ in
            let pdfs = dropped.filter { QuickAction.kind(of: $0) == .pdf }
            if pdfs.count < dropped.count {
                error = "Only PDFs can be edited here."
            }
            add(pdfs)
            return true
        }
        .task(id: urls.first) {
            loadPreview()
        }
        .onChange(of: kind) { _, newValue in
            error = nil
            suffix = newValue == .text ? "-text" : PDFToolRequest(kind: newValue).suffix
        }
        .onChange(of: pageSize) { _, newValue in
            if kind == .pageSize { suffix = "-\(newValue.rawValue)" }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                ForEach(PDFToolRequest.Kind.allCases) { tool in
                    toolButton(tool)
                }
            }
            .controlSize(.small)

            HStack(spacing: Theme.Space.sm) {
                Text(kind.label)
                    .font(Theme.Text.sectionTitle)
                Spacer()
                if let pageCount, pageCount > 0 {
                    Badge(text: "\(pageCount) page\(pageCount == 1 ? "" : "s")", tone: .neutral)
                }
            }

            settings

            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: "Add to name", help: "The new file is written next to the original with this ending.")
                TextField("Add to name", text: $suffix)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
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
    private var settings: some View {
        switch kind {
        case .rotate:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Rotate", selection: $rotation) {
                    Text("90° right").tag(90)
                    Text("180°").tag(180)
                    Text("90° left").tag(270)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                note("Adds to each page's current rotation. Text and vectors stay intact.")
            }

        case .organize:
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "New order", help: "Leave empty to keep the current sequence. Use ranges like 2-4.")
                    TextField("New order", text: $orderText, prompt: Text("e.g. 3, 1, 2-4"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Remove pages", help: "One page or a range, separated by commas.")
                    TextField("Remove pages", text: $deleteText, prompt: Text("e.g. 2, 5"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Reverse the final order", isOn: $reversePages)

                if !pagesValid {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    note("Leave the order empty to keep the current sequence. Use ranges like 2-4.")
                }
            }

        case .pageSize:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Page size", selection: $pageSize) {
                    ForEach(PDFPageSize.allCases) { Text($0.label).tag($0) }
                }
                note("Each page is scaled and centered with a small margin. Text stays text.")
            }

        case .stamp:
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Page numbers", isOn: $pageNumbers)
                TextField("Watermark text", text: $watermark, prompt: Text("e.g. DRAFT"))
                    .textFieldStyle(.roundedBorder)
                note("Numbers sit at the bottom of each page. Watermarks are drawn diagonally across every page.")
            }

        case .protect:
            VStack(alignment: .leading, spacing: 10) {
                if isLocked {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(text: "Current password", help: "The password this PDF already uses.")
                        SecureField("Current password", text: $sourcePassword)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "New password")
                    SecureField("New password", text: $password)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

                note("The output opens with the new password. There is no recovery if you lose it.")
            }

        case .unlock:
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Current password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                note("Writes an unprotected copy next to the original.")
            }

        case .text:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Format", selection: $textTarget) {
                    Text("Markdown").tag(ConversionTarget.markdown)
                    Text("Plain Text").tag(ConversionTarget.text)
                    Text("HTML").tag(ConversionTarget.html)
                }
                note("Reads the document's existing text layer. Run OCR first for scans.")
            }
        }

        if kind != .protect && kind != .unlock {
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Password", help: "Only needed if this PDF, or another PDF in the batch, is locked.")
                SecureField("Password (if locked)", text: $password)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func toolButton(_ tool: PDFToolRequest.Kind) -> some View {
        let button = Button {
            kind = tool
        } label: {
            Label(tool.shortTitle, systemImage: tool.systemImage)
                .font(Theme.Text.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .help(tool.label)

        if kind == tool {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(10)
        } else if urls.isEmpty {
            Text("Choose PDFs to see a preview.")
                .font(Theme.Text.body)
                .foregroundStyle(.secondary)
        } else if isLocked {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Locked PDF")
                    .font(Theme.Text.body.weight(.medium))
                Text("Enter its password to preview and apply.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if previewFailed {
            Label("No preview for this file.", systemImage: "doc.badge.exclamationmark")
                .font(Theme.Text.body)
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var pageLine: String {
        if previewFailed { return "No preview for this file" }
        if isLocked { return "Locked PDF · enter its password" }
        guard let count = pageCount, count > 0 else { return "Preview of the first page" }
        return "\(count) page\(count == 1 ? "" : "s") · preview of the first page"
    }

    private var fileSummary: String {
        guard let first = urls.first else { return "No PDFs selected" }
        return urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) and \(urls.count - 1) more"
    }

    private var parsedOrder: [Int]? { parsePages(orderText) }
    private var parsedDelete: [Int]? { parsePages(deleteText) }

    private var pagesValid: Bool {
        guard kind == .organize else { return true }
        guard let order = parsedOrder, let delete = parsedDelete else { return false }
        guard Set(order).count == order.count else { return false }
        guard Set(delete).count == delete.count else { return false }
        guard let count = pageCount, count > 0 else { return true }
        guard (order + delete).allSatisfy({ (1...count).contains($0) }) else { return false }

        // Deleting a page wins over including it in the order; make sure something remains.
        let removed = Set(delete)
        let remaining = order.isEmpty
            ? (1...count).filter { !removed.contains($0) }
            : order.filter { !removed.contains($0) }
        return !remaining.isEmpty
    }

    private var validationMessage: String {
        if let order = parsedOrder, Set(order).count != order.count {
            return "The new order lists the same page twice."
        }
        if let delete = parsedDelete, Set(delete).count != delete.count {
            return "The remove list names the same page twice."
        }
        if let count = pageCount, count > 0 {
            return "Use page numbers from 1 to \(count). At least one page must remain."
        }
        return "Use page numbers from 1 upward, without duplicates."
    }

    private var canRun: Bool {
        guard !urls.isEmpty, !isRunning, !model.isBusy else { return false }
        switch kind {
        case .organize:
            let hasWork = !orderText.trimmingCharacters(in: .whitespaces).isEmpty
                || !deleteText.trimmingCharacters(in: .whitespaces).isEmpty
                || reversePages
            return hasWork && pagesValid
        case .stamp:
            return pageNumbers || !watermark.trimmingCharacters(in: .whitespaces).isEmpty
        case .protect:
            return !password.isEmpty && (!isLocked || !sourcePassword.isEmpty)
        case .unlock:
            return !password.isEmpty
        default:
            return true
        }
    }

    private var request: PDFToolRequest {
        var request = PDFToolRequest(kind: kind)
        request.rotation = rotation
        request.pageOrder = parsedOrder ?? []
        request.deletePages = parsedDelete ?? []
        request.reversePages = reversePages
        request.pageSize = pageSize
        request.pageNumbers = pageNumbers
        request.watermark = watermark
        request.password = password
        request.sourcePassword = sourcePassword
        request.textTarget = textTarget
        return request
    }

    private func add(_ new: [URL]) {
        var seen = Set(urls.map(\.path))
        urls += new.filter { seen.insert($0.path).inserted }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func loadPreview() {
        thumbnail = nil
        pageCount = nil
        isLocked = false
        previewFailed = false
        guard let url = urls.first else { return }
        guard let document = PDFDocument(url: url) else {
            previewFailed = true
            return
        }
        pageCount = document.pageCount
        isLocked = document.isLocked
        guard !isLocked else { return }
        if let page = document.page(at: 0) {
            thumbnail = page.thumbnail(of: NSSize(width: 300, height: 360), for: .cropBox)
        }
    }

    private func run() {
        error = nil
        let job = ConversionJob(
            label: "PDF Tools",
            suffix: suffix,
            quality: 0.9,
            preserveMetadata: true,
            pdfTool: request
        )
        isRunning = true
        Task {
            let summary = await model.runTool(urls: urls, job: job)
            isRunning = false
            if let summary {
                if summary.converted > 0 {
                    dismiss()
                } else {
                    error = "Nothing changed. Check the page numbers, the password, or the file."
                }
            } else {
                error = "The tool could not run. Try again after the current conversion finishes."
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Parses "1, 3, 2-4" into 1-based page numbers; nil when the text is malformed.
    private func parsePages(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [Int] = []
        for piece in trimmed.split(separator: ",", omittingEmptySubsequences: true) {
            let token = piece.trimmingCharacters(in: .whitespaces)
            if token.contains("-") {
                let parts = token.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let end = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      start > 0, end >= start else { return nil }
                result.append(contentsOf: start...end)
            } else {
                guard let number = Int(token), number > 0 else { return nil }
                result.append(number)
            }
        }
        return result
    }
}

private extension PDFToolRequest.Kind {
    var shortTitle: String {
        switch self {
        case .rotate: "Rotate"
        case .organize: "Organize"
        case .pageSize: "Page Size"
        case .stamp: "Stamp"
        case .protect: "Protect"
        case .unlock: "Unlock"
        case .text: "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .rotate: "rotate.right"
        case .organize: "list.number"
        case .pageSize: "rectangle.portrait"
        case .stamp: "number.square"
        case .protect: "lock"
        case .unlock: "lock.open"
        case .text: "text.alignleft"
        }
    }
}
