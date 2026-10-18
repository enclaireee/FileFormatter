import CoreGraphics
import Foundation

enum PDFConverter {
    static func data(image: CGImage) throws -> Data {
        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.writeFailed("Could not create a PDF context.")
        }

        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
