import Quartz
import AppKit
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

    public static func compress(source: URL, destination: URL) throws {
        let name = source.lastPathComponent
        guard let document = PDFDocument(url: source) else {
            throw ConversionError.cannotReadSource(name)
        }
        if document.isLocked { throw ConversionError.cannotReadSource("\(name) is password-protected") }
        // PDFKit's write options don't recompress images, so redraw through the
        // system "Reduce File Size" Quartz filter (keeps text and vectors).
        let temporary = temporaryURL(for: destination)
        guard let pdf = CGPDFDocument(source as CFURL),
              let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")),
              let context = CGContext(temporary as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }
        filter.apply(to: context)
        for index in 1...max(pdf.numberOfPages, 1) {
            guard let page = pdf.page(at: index) else { continue }
            var box = page.getBoxRect(.mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
        filter.remove(from: context)
        func size(_ url: URL) -> Int {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        if size(temporary) >= size(source) {
            try? FileManager.default.removeItem(at: temporary)
            throw ConversionError.notSmaller
        }
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
