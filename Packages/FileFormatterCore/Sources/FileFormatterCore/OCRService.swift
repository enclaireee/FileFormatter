import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

public struct OCRLine: Sendable, Hashable {
    public let text: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct OCRResult: Sendable {
    public let text: String
    public let lines: [OCRLine]
}

public enum OCRError: LocalizedError, Sendable {
    case unreadablePDF
    case recognitionFailed(String)
    case noPages

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            "The PDF could not be read for OCR."
        case .recognitionFailed(let message):
            "Text recognition failed. \(message)"
        case .noPages:
            "The document has no pages to recognize."
        }
    }
}

public actor OCRService {
    public init() {}

    // Stateless, so nonisolated: makeSearchablePDF can call it inside a per-page autoreleasepool.
    nonisolated public func recognize(
        image: CGImage,
        languages: [String] = []
    ) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
        } catch {
            throw OCRError.recognitionFailed(error.localizedDescription)
        }

        let observations = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(
                text: candidate.string,
                x: box.origin.x,
                y: box.origin.y,
                width: box.width,
                height: box.height
            )
        }

        return OCRResult(
            text: observations.map(\.text).joined(separator: "\n"),
            lines: observations
        )
    }

    public func makeSearchablePDF(
        image: CGImage,
        destination: URL,
        languages: [String] = []
    ) throws {
        let result = try recognize(image: image, languages: languages)
        let mediaBox = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )

        guard let context = CGContext(destination as CFURL, mediaBox: [mediaBox], nil) else {
            throw OCRError.recognitionFailed("Could not create a PDF context.")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        drawInvisible(result.lines, in: mediaBox, context: context)
        context.endPDFPage()
        context.closePDF()
    }

    nonisolated public func makeSearchablePDF(
        source: URL,
        destination: URL,
        languages: [String] = []
    ) throws {
        guard let document = PDFDocument(url: source) else {
            throw OCRError.unreadablePDF
        }
        guard document.pageCount > 0 else {
            throw OCRError.noPages
        }

        var firstBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let first = document.page(at: 0) {
            firstBox = first.bounds(for: .mediaBox)
        }
        guard let context = CGContext(destination as CFURL, mediaBox: [firstBox], nil) else {
            throw OCRError.recognitionFailed("Could not create a PDF context.")
        }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            // Each 2x page bitmap is autoreleased; drain per page or every page stays alive until the loop ends.
            try autoreleasepool {
                let bounds = page.bounds(for: .mediaBox)
                let image = try PDFPageRenderer.render(page: page)
                let result = try recognize(image: image, languages: languages)

                let pageInfo = [kCGPDFContextMediaBox as String: NSValue(rect: bounds)] as CFDictionary
                context.beginPDFPage(pageInfo)
                context.saveGState()
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()
                drawInvisible(result.lines, in: bounds, context: context)
                context.endPDFPage()
            }
        }

        context.closePDF()
    }

    nonisolated private func drawInvisible(
        _ lines: [OCRLine],
        in page: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let height = CGFloat(line.height) * page.height
            let fontSize = max(height * 0.8, 4)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font
            ]
            let attributed = NSAttributedString(string: line.text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(
                x: page.minX + CGFloat(line.x) * page.width,
                y: page.minY + CGFloat(line.y) * page.height
            )
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }
}
