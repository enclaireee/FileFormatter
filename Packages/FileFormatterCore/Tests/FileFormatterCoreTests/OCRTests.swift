import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FileFormatterCore

@Suite("OCR")
struct OCRTests {
    @Test func recognizesRenderedTextAndCreatesSearchablePDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterOCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = try makeTextImage("Hello FileFormatter")
        let service = OCRService()
        let result = try await service.recognize(image: image)
        #expect(result.text.lowercased().contains("fileformatter"))

        let pdf = directory.appendingPathComponent("ocr.pdf")
        try await service.makeSearchablePDF(image: image, destination: pdf)
        let document = try #require(PDFDocument(url: pdf))
        let text = (document.string ?? "").lowercased()
        #expect(text.contains("fileformatter"))
    }

    @Test func plansAndConvertsPDFToSearchablePDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterOCRBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = try makeTextImage("Searchable PDF")
        let imagePDF = directory.appendingPathComponent("source.pdf")
        let ocr = OCRService()
        try await ocr.makeSearchablePDF(image: image, destination: imagePDF)

        let service = ConversionService()
        let plan = try await service.makePlan(
            urls: [imagePDF],
            targets: TargetRecipe(image: .png, data: .json),
            suffix: "-ocr",
            pdfMode: .searchable
        )
        let item = try #require(plan.items.first)
        #expect(item.pdfMode == .searchable)
        #expect(item.outputName == "source-ocr-ocr.pdf")

        let result = try await service.convert(
            item,
            options: ConversionOptions(
                target: .searchablePDF,
                quality: 1,
                suffix: "-ocr",
                preserveMetadata: false
            )
        )
        let document = try #require(PDFDocument(url: result.url))
        #expect((document.string ?? "").lowercased().contains("searchable"))
    }

    private func makeTextImage(_ text: String) throws -> CGImage {
        let size = NSSize(width: 900, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 40, y: 90), withAttributes: attributes)
        image.unlockFocus()

        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw OCRError.recognitionFailed("Could not render the test image.")
        }
        return cgImage
    }
}
