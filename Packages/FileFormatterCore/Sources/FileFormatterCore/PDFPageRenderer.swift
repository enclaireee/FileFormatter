import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Synchronization

enum PDFPageRenderer {
    // ponytail: one cached document, so a batch of pages from one PDF parses it once; key by URL+mtime.
    // Rendering runs under the lock (PDFDocument is not thread-safe); a per-document cache if mixed PDFs ever queue up.
    private static let cached = Mutex<(url: URL, modified: Date?, document: PDFDocument)?>(nil)

    static func render(source: URL, pageNumber: Int, scale: CGFloat = 2.0) throws -> CGImage {
        let modified = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return try cached.withLock { cached in
            if cached?.url != source || cached?.modified != modified {
                guard let document = PDFDocument(url: source) else {
                    throw ConversionError.cannotReadSource(source.lastPathComponent)
                }
                cached = (source, modified, document)
            }
            guard pageNumber >= 1, let page = cached?.document.page(at: pageNumber - 1) else {
                throw ConversionError.cannotReadSource("\(source.lastPathComponent) page \(pageNumber)")
            }
            return try render(page: page, scale: scale)
        }
    }

    static func render(page: PDFPage, scale: CGFloat = 2.0) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let target = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
        // The NSImage thumbnail is autoreleased; drain it here so a batch of pages doesn't pile them up.
        let image: CGImage? = autoreleasepool {
            let thumbnail = page.thumbnail(of: target, for: .cropBox)
            var rect = CGRect(origin: .zero, size: thumbnail.size)
            return thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let image else {
            throw ConversionError.cannotReadSource("PDF page \((page.document?.index(for: page) ?? 0) + 1)")
        }
        return image
    }
}
