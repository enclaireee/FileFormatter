import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum PDFPageRenderer {
    static func render(source: URL, pageNumber: Int, scale: CGFloat = 2.0) throws -> CGImage {
        guard let document = PDFDocument(url: source) else {
            throw ConversionError.cannotReadSource(source.lastPathComponent)
        }
        guard pageNumber >= 1, let page = document.page(at: pageNumber - 1) else {
            throw ConversionError.cannotReadSource(
                "\(source.lastPathComponent) page \(pageNumber)"
            )
        }

        let bounds = page.bounds(for: .cropBox)
        let target = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
        let thumbnail = page.thumbnail(of: target, for: .cropBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw ConversionError.cannotReadSource(
                "\(source.lastPathComponent) page \(pageNumber)"
            )
        }
        return image
    }
}
