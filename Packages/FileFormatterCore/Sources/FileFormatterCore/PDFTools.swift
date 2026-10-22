import Quartz
import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit

public enum PDFTools {
    public static func merge(sources: [URL], destination: URL) throws {
        guard !sources.isEmpty else {
            throw ConversionError.unsupportedTarget("Merge needs at least one file")
        }
        let output = PDFDocument()
        for url in sources {
            let name = url.lastPathComponent
            if let document = PDFDocument(url: url) {
                if document.isLocked {
                    throw ConversionError.cannotReadSource("\(name) is password-protected")
                }
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    output.insert(page, at: output.pageCount)
                }
            } else {
                output.insert(try imagePage(url), at: output.pageCount)
            }
        }
        try write(output, to: destination)
    }

    public static func extractPage(source: URL, pageNumber: Int, destination: URL) throws {
        let name = source.lastPathComponent
        guard let document = PDFDocument(url: source) else {
            throw ConversionError.cannotReadSource(name)
        }
        if document.isLocked { throw ConversionError.cannotReadSource("\(name) is password-protected") }
        guard pageNumber >= 1, pageNumber <= document.pageCount, let page = document.page(at: pageNumber - 1) else {
            throw ConversionError.cannotReadSource("\(name) page \(pageNumber)")
        }
        let output = PDFDocument()
        output.insert(page, at: 0)
        try write(output, to: destination)
    }

    /// Light, Balanced, Strong: JPEG quality and longest image side inside the PDF.
    public static let compressionLevels: [(quality: Double, maxPixelSize: Int)] = [(0.8, 3000), (0.6, 2000), (0.4, 1200)]

    /// Redraws the PDF with recompressed images (text and vectors stay). With `targetBytes`,
    /// tries each level from lightest and keeps the first that fits, else the smallest.
    public static func compress(
        source: URL,
        destination: URL,
        quality: Double? = nil,
        maxPixelSize: Int? = nil,
        targetBytes: UInt64? = nil
    ) throws {
        let name = source.lastPathComponent
        guard let document = PDFDocument(url: source) else {
            throw ConversionError.cannotReadSource(name)
        }
        if document.isLocked { throw ConversionError.cannotReadSource("\(name) is password-protected") }
        func size(_ url: URL) -> UInt64 {
            UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let levels: [(Double?, Int?)] = targetBytes == nil
            ? [(quality, maxPixelSize)]
            : compressionLevels.map { ($0.quality, $0.maxPixelSize) }
        var best: URL?
        defer { if let best { try? FileManager.default.removeItem(at: best) } }
        for (quality, maxPixelSize) in levels {
            let attempt = try redraw(source, for: destination, quality: quality, maxPixelSize: maxPixelSize)
            if let old = best, size(old) <= size(attempt) {
                try? FileManager.default.removeItem(at: attempt)
            } else {
                if let old = best { try? FileManager.default.removeItem(at: old) }
                best = attempt
            }
            if let targetBytes, let best, size(best) <= targetBytes { break }
        }
        guard let winner = best, size(winner) < size(source) else { throw ConversionError.notSmaller }
        try ImageConverter.install(temporary: winner, at: destination)
        best = nil
    }

    /// One pass through the system "Reduce File Size" Quartz filter, with its image settings overridden.
    private static func redraw(_ source: URL, for destination: URL, quality: Double?, maxPixelSize: Int?) throws -> URL {
        let temporary = temporaryURL(for: destination)
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        var properties = NSDictionary(contentsOf: filterURL) as? [String: Any] ?? [:]
        if quality != nil || maxPixelSize != nil,
           var data = properties["FilterData"] as? [String: Any],
           var color = data["ColorSettings"] as? [String: Any],
           var image = color["ImageSettings"] as? [String: Any] {
            if let quality { image["Compression Quality"] = quality }
            if let maxPixelSize, var scale = image["ImageScaleSettings"] as? [String: Any] {
                scale["ImageSizeMax"] = maxPixelSize
                image["ImageScaleSettings"] = scale
            }
            color["ImageSettings"] = image
            data["ColorSettings"] = color
            properties["FilterData"] = data
        }
        guard let pdf = CGPDFDocument(source as CFURL),
              let filter = QuartzFilter(properties: properties),
              let context = CGContext(temporary as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }
        filter.apply(to: context)
        for index in 1...max(pdf.numberOfPages, 1) {
            guard let page = pdf.page(at: index) else { continue }
            // Drains each page's decoded and recompressed images instead of holding them all until closePDF.
            autoreleasepool {
                var box = page.getBoxRect(.mediaBox)
                let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
                context.beginPDFPage(info as CFDictionary)
                context.drawPDFPage(page)
                context.endPDFPage()
            }
        }
        context.closePDF()
        filter.remove(from: context)
        return temporary
    }

    // MARK: - PDF tools

    /// Runs one tool from the PDF toolkit: rotate, organize, resize, stamp, protect, unlock or extract text.
    public static func apply(_ tool: PDFToolRequest, source: URL, destination: URL) throws {
        // `.protect` uses `password` for the new file, so an existing lock needs its own password.
        let document = try open(source, password: tool.kind == .protect ? tool.sourcePassword : tool.password)
        guard document.pageCount > 0 else {
            throw ConversionError.cannotReadSource("\(source.lastPathComponent) has no pages")
        }

        switch tool.kind {
        case .text:
            try writeText(document, to: destination, target: tool.textTarget)
        case .rotate:
            try rotate(document, degrees: tool.rotation, destination: destination)
        case .organize:
            try organize(document, order: tool.pageOrder, deleting: tool.deletePages,
                         reverse: tool.reversePages, destination: destination)
        case .pageSize:
            try resize(document, to: tool.pageSize.size, destination: destination)
        case .stamp:
            try stamp(document, pageNumbers: tool.pageNumbers,
                      watermark: tool.watermark, destination: destination)
        case .protect:
            guard !tool.password.isEmpty else {
                throw ConversionError.unsupportedTarget("A password is required to protect a PDF")
            }
            try protect(document, password: tool.password, destination: destination)
        case .unlock:
            try writeUnprotected(document, to: destination)
        }
    }

    private static func open(_ source: URL, password: String) throws -> PDFDocument {
        guard let document = PDFDocument(url: source) else {
            throw ConversionError.cannotReadSource(source.lastPathComponent)
        }
        if document.isLocked {
            guard !password.isEmpty, document.unlock(withPassword: password) else {
                throw ConversionError.cannotReadSource(
                    "\(source.lastPathComponent) is password-protected. Enter its password."
                )
            }
        }
        return document
    }

    private static func rotate(_ document: PDFDocument, degrees: Int, destination: URL) throws {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        try write(document, to: destination)
    }

    private static func organize(
        _ document: PDFDocument,
        order: [Int],
        deleting: [Int],
        reverse: Bool,
        destination: URL
    ) throws {
        let count = document.pageCount
        let removed = Set(deleting)
        var indices = order.isEmpty
            ? Array(1...count).filter { !removed.contains($0) }
            : order.filter { !removed.contains($0) }
        if reverse { indices.reverse() }
        guard !indices.isEmpty else {
            throw ConversionError.unsupportedTarget("Every page was removed")
        }
        var seen = Set<Int>()
        for number in indices {
            guard (1...count).contains(number), seen.insert(number).inserted else {
                throw ConversionError.unsupportedTarget("Page \(number) is not in this document")
            }
        }

        let output = PDFDocument()
        for number in indices {
            guard let page = document.page(at: number - 1) else { continue }
            output.insert(page, at: output.pageCount)
        }
        try write(output, to: destination)
    }

    /// Draws each page into a same-sized new page, keeping text and vectors rather than rasterizing.
    private static func resize(_ document: PDFDocument, to size: CGSize, destination: URL) throws {
        let margin: CGFloat = 18
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(destination as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            autoreleasepool {
                let pageInfo = [kCGPDFContextMediaBox as String: NSValue(rect: box)] as CFDictionary
                context.beginPDFPage(pageInfo)
                let source = page.bounds(for: .mediaBox)
                let quarterTurn = abs(page.rotation % 180) == 90
                let visual = quarterTurn
                    ? CGSize(width: source.height, height: source.width)
                    : source.size
                let scale = min(
                    (size.width - margin * 2) / max(visual.width, 1),
                    (size.height - margin * 2) / max(visual.height, 1)
                )
                context.saveGState()
                context.translateBy(
                    x: (size.width - visual.width * scale) / 2,
                    y: (size.height - visual.height * scale) / 2
                )
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()
                context.endPDFPage()
            }
        }
        context.closePDF()
    }

    private static func stamp(
        _ document: PDFDocument,
        pageNumbers: Bool,
        watermark: String,
        destination: URL
    ) throws {
        var box = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(destination as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }
        let total = document.pageCount

        for index in 0..<total {
            guard let page = document.page(at: index) else { continue }
            autoreleasepool {
                let bounds = page.bounds(for: .mediaBox)
                let info = [kCGPDFContextMediaBox as String: NSValue(rect: bounds)] as CFDictionary
                context.beginPDFPage(info)
                context.saveGState()
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()

                if !watermark.isEmpty {
                    drawWatermark(watermark, in: bounds, context: context)
                }
                if pageNumbers {
                    drawPageNumber(index + 1, of: total, in: bounds, context: context)
                }
                context.endPDFPage()
            }
        }
        context.closePDF()
    }

    private static func drawPageNumber(_ number: Int, of total: Int, in page: CGRect, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\(number) / \(total)", attributes: [.font: font])
        )
        let width = CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.4, alpha: 0.9))
        context.textPosition = CGPoint(x: page.midX - width / 2, y: page.minY + 18)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawWatermark(_ text: String, in page: CGRect, context: CGContext) {
        let fontSize = min(96, max(24, page.width / 8))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let fit = min(1, (page.width * 0.8) / max(bounds.width, 1))
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.5, alpha: 0.12))
        context.translateBy(x: page.midX, y: page.midY)
        context.rotate(by: .pi / 4)
        context.scaleBy(x: fit, y: fit)
        context.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func protect(_ document: PDFDocument, password: String, destination: URL) throws {
        let options: [CFString: Any] = [
            kCGPDFContextUserPassword: password,
            kCGPDFContextOwnerPassword: password,
            kCGPDFContextEncryptionKeyLength: NSNumber(value: 128)
        ]
        try draw(document, to: destination, options: options as CFDictionary)
    }

    /// Copies pages into a new document: writing the unlocked source directly would keep its encryption dictionary.
    private static func writeUnprotected(_ document: PDFDocument, to destination: URL) throws {
        let output = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            output.insert(page, at: output.pageCount)
        }
        try write(output, to: destination)
    }

    private static func draw(_ document: PDFDocument, to destination: URL, options: CFDictionary?) throws {
        var box = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(destination as CFURL, mediaBox: &box, options) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            autoreleasepool {
                let bounds = page.bounds(for: .mediaBox)
                let info = [kCGPDFContextMediaBox as String: NSValue(rect: bounds)] as CFDictionary
                context.beginPDFPage(info)
                context.saveGState()
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()
                context.endPDFPage()
            }
        }
        context.closePDF()
    }

    private static func writeText(_ document: PDFDocument, to destination: URL, target: ConversionTarget) throws {
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string ?? "" }
        let text = pages.joined(separator: "\n\n")
        let output: String
        switch target {
        case .html:
            let escaped = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let paragraphs = escaped
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "    <p>\($0)</p>" }
                .joined(separator: "\n")
            output = """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>\(destination.deletingPathExtension().lastPathComponent)</title></head>
            <body>
            \(paragraphs)
            </body>
            </html>
            """
        default:
            output = text
        }
        let temporary = temporaryURL(for: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let data = output.data(using: .utf8) else {
            throw ConversionError.writeFailed("The extracted text could not be written as UTF-8.")
        }
        try data.write(to: temporary)
        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private static func temporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".fileformatter-\(UUID().uuidString).\(destination.pathExtension)")
    }

    private static func write(_ document: PDFDocument, to destination: URL) throws {
        let temporary = temporaryURL(for: destination)
        guard document.write(to: temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }
        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private static func imagePage(_ url: URL) throws -> PDFPage {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(w, h),
              ] as CFDictionary)
        else { throw ConversionError.cannotReadSource(name) }
        // 1 pixel = 1 point (72 dpi)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let page = PDFPage(image: nsImage) else { throw ConversionError.cannotReadSource(name) }
        return page
    }
}
