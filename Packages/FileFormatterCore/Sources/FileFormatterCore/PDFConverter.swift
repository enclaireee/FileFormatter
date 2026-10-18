import CoreGraphics
import Foundation

enum PDFConverter {
    static func convert(image: CGImage, destination: URL) throws {
        let mediaBox = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        let directory = destination.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let context = CGContext(
            temporary as CFURL,
            mediaBox: [mediaBox],
            nil
        ) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }

        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()

        try ImageConverter.install(temporary: temporary, at: destination)
    }
}
