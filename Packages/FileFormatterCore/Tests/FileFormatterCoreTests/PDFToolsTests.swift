import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import FileFormatterCore

@Suite("PDF tools")
struct PDFToolsTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makePDF(at url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func makePNG(at url: URL, width: Int, height: Int, noisy: Bool) {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        if noisy {
            var g = SystemRandomNumberGenerator()
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    @Test func mergesPDFsAndImage() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let a = d.appendingPathComponent("a.pdf"), b = d.appendingPathComponent("b.pdf")
        let p = d.appendingPathComponent("p.png"), out = d.appendingPathComponent("out.pdf")
        makePDF(at: a, pages: 2); makePDF(at: b, pages: 3)
        makePNG(at: p, width: 120, height: 80, noisy: false)
        try PDFTools.merge(sources: [a, b, p], destination: out)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 6)
        let bounds = try #require(doc.page(at: 5)).bounds(for: .mediaBox)
        #expect(bounds.size == CGSize(width: 120, height: 80))
    }

    @Test func mergeEmptyThrows() {
        #expect(throws: ConversionError.self) {
            try PDFTools.merge(sources: [], destination: URL(fileURLWithPath: "/tmp/x.pdf"))
        }
    }

    @Test func extractsPage() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("s.pdf"), out = d.appendingPathComponent("o.pdf")
        makePDF(at: src, pages: 3)
        try PDFTools.extractPage(source: src, pageNumber: 2, destination: out)
        #expect(PDFDocument(url: out)?.pageCount == 1)
        #expect(throws: ConversionError.self) {
            try PDFTools.extractPage(source: src, pageNumber: 4, destination: d.appendingPathComponent("x.pdf"))
        }
    }

    @Test func compressesNoisyImagePDF() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let png = d.appendingPathComponent("n.png"), big = d.appendingPathComponent("big.pdf")
        let out = d.appendingPathComponent("small.pdf")
        makePNG(at: png, width: 2500, height: 2500, noisy: true)
        // PDFKit-made image pages are already JPEG; draw raw via CoreGraphics so there is something to shrink.
        var box = CGRect(x: 0, y: 0, width: 250, height: 250)
        let ctx = try #require(CGContext(big as CFURL, mediaBox: &box, nil))
        let img = try #require(CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        ctx.beginPDFPage(nil); ctx.draw(img, in: box); ctx.endPDFPage(); ctx.closePDF()
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        try PDFTools.compress(source: big, destination: out)
        #expect(size(out) < size(big) / 2)
        #expect(PDFDocument(url: out)?.pageCount == 1)
    }

    @Test func strongerLevelIsSmallerAndTargetFits() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let png = d.appendingPathComponent("n.png"), big = d.appendingPathComponent("big.pdf")
        makePNG(at: png, width: 2500, height: 2500, noisy: true)
        var box = CGRect(x: 0, y: 0, width: 250, height: 250)
        let ctx = try #require(CGContext(big as CFURL, mediaBox: &box, nil))
        let img = try #require(CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        ctx.beginPDFPage(nil); ctx.draw(img, in: box); ctx.endPDFPage(); ctx.closePDF()
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

        let light = d.appendingPathComponent("light.pdf"), strong = d.appendingPathComponent("strong.pdf")
        let levels = PDFTools.compressionLevels
        try PDFTools.compress(source: big, destination: light, quality: levels[0].quality, maxPixelSize: levels[0].maxPixelSize)
        try PDFTools.compress(source: big, destination: strong, quality: levels[2].quality, maxPixelSize: levels[2].maxPixelSize)
        #expect(size(strong) < size(light))

        let fit = d.appendingPathComponent("fit.pdf")
        try PDFTools.compress(source: big, destination: fit, targetBytes: UInt64(size(light) - 1))
        #expect(size(fit) < size(light))
    }

    @Test func compressTinyPDFNeverGrows() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("t.pdf"), out = d.appendingPathComponent("o.pdf")
        makePDF(at: src, pages: 1)
        do {
            try PDFTools.compress(source: src, destination: out)
            func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            #expect(size(out) <= size(src))
        } catch ConversionError.notSmaller {
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    private func makeTextPDF(at url: URL, text: String) {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        ctx.textPosition = CGPoint(x: 24, y: 300)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    @Test func rotatesPagesLosslessly() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("r.pdf"), out = d.appendingPathComponent("r-out.pdf")
        makePDF(at: src, pages: 2)
        var request = PDFToolRequest(kind: .rotate)
        request.rotation = 90
        try PDFTools.apply(request, source: src, destination: out)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.rotation == 90)
        #expect(doc.page(at: 1)?.rotation == 90)
    }

    @Test func organizesAndRemovesPages() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("o.pdf"), out = d.appendingPathComponent("o-out.pdf")
        makePDF(at: src, pages: 4)
        var request = PDFToolRequest(kind: .organize)
        request.pageOrder = [4, 2]
        request.deletePages = [1]
        try PDFTools.apply(request, source: src, destination: out)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)

        var invalid = PDFToolRequest(kind: .organize)
        invalid.pageOrder = [5]
        #expect(throws: ConversionError.self) {
            try PDFTools.apply(invalid, source: src, destination: d.appendingPathComponent("bad.pdf"))
        }
    }

    @Test func changesPageSize() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("s.pdf"), out = d.appendingPathComponent("s-a4.pdf")
        makePDF(at: src, pages: 2)
        var request = PDFToolRequest(kind: .pageSize)
        request.pageSize = .a4
        try PDFTools.apply(request, source: src, destination: out)
        let doc = try #require(PDFDocument(url: out))
        let size = try #require(doc.page(at: 0)).bounds(for: .mediaBox).size
        #expect(abs(size.width - PDFPageSize.a4.size.width) < 1)
        #expect(abs(size.height - PDFPageSize.a4.size.height) < 1)
        #expect(doc.pageCount == 2)
    }

    @Test func extractsTextAsMarkdown() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("t.pdf"), out = d.appendingPathComponent("t.md")
        makeTextPDF(at: src, text: "Hello FileFormatter")
        var request = PDFToolRequest(kind: .text)
        request.textTarget = .markdown
        try PDFTools.apply(request, source: src, destination: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.contains("Hello FileFormatter"))
    }

    @Test func protectsAndUnlocks() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("p.pdf")
        let locked = d.appendingPathComponent("locked.pdf")
        let opened = d.appendingPathComponent("opened.pdf")
        makePDF(at: src, pages: 2)

        var protect = PDFToolRequest(kind: .protect)
        protect.password = "secret"
        try PDFTools.apply(protect, source: src, destination: locked)
        #expect(PDFDocument(url: locked)?.isLocked == true)

        var unlock = PDFToolRequest(kind: .unlock)
        unlock.password = "secret"
        try PDFTools.apply(unlock, source: locked, destination: opened)
        let doc = try #require(PDFDocument(url: opened))
        #expect(!doc.isLocked)
        #expect(doc.pageCount == 2)

        var wrong = PDFToolRequest(kind: .unlock)
        wrong.password = "nope"
        #expect(throws: ConversionError.self) {
            try PDFTools.apply(wrong, source: locked, destination: d.appendingPathComponent("no.pdf"))
        }
    }

    @Test func toolPlanKeepsImageFormatAndNamesPDFs() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let png = d.appendingPathComponent("photo.png")
        let pdf = d.appendingPathComponent("doc.pdf")
        makePNG(at: png, width: 60, height: 40, noisy: false)
        makePDF(at: pdf, pages: 2)
        let service = ConversionService()

        let images = try await service.makeToolPlan(
            urls: [png],
            imageEdit: ImageEdit(rotation: 90),
            pdfTool: nil,
            suffix: "-rotated"
        )
        let image = try #require(images.items.first)
        #expect(image.outputName == "photo-rotated.png")
        #expect(image.target == .png)
        #expect(image.fidelity == .lossless)

        let converted = try await service.convert(image, options: ConversionOptions(
            target: .png, quality: 0.9, suffix: "-rotated", preserveMetadata: true,
            imageEdit: ImageEdit(rotation: 90)
        ))
        let source = try #require(CGImageSourceCreateWithURL(converted.url as CFURL, nil))
        let output = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(output.width == 40 && output.height == 60)

        var rotate = PDFToolRequest(kind: .rotate)
        rotate.rotation = 180
        let pdfs = try await service.makeToolPlan(
            urls: [pdf],
            imageEdit: nil,
            pdfTool: rotate,
            suffix: "-rotated"
        )
        let item = try #require(pdfs.items.first)
        #expect(item.outputName == "doc-rotated.pdf")
        #expect(item.pdfMode == .tool)
    }

    @Test func serviceRunsPDFToolsAndText() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let pdf = d.appendingPathComponent("tool.pdf")
        makePDF(at: pdf, pages: 2)
        let service = ConversionService()

        var rotate = PDFToolRequest(kind: .rotate)
        rotate.rotation = 90
        let plan = try await service.makeToolPlan(
            urls: [pdf], imageEdit: nil, pdfTool: rotate, suffix: "-rotated"
        )
        let item = try #require(plan.items.first)
        let result = try await service.convert(item, options: ConversionOptions(
            target: .pdf, quality: 0.9, suffix: "-rotated",
            preserveMetadata: true, pdfTool: rotate
        ))
        #expect(PDFDocument(url: result.url)?.page(at: 0)?.rotation == 90)

        let textURL = d.appendingPathComponent("words.pdf")
        makeTextPDF(at: textURL, text: "Toolkit text")
        var text = PDFToolRequest(kind: .text)
        text.textTarget = .markdown
        let textPlan = try await service.makeToolPlan(
            urls: [textURL], imageEdit: nil, pdfTool: text, suffix: "-text"
        )
        let textItem = try #require(textPlan.items.first)
        let textResult = try await service.convert(textItem, options: ConversionOptions(
            target: .markdown, quality: 0.9, suffix: "-text",
            preserveMetadata: true, pdfTool: text
        ))
        #expect(textItem.pdfMode == .text)
        #expect(try String(contentsOf: textResult.url, encoding: .utf8).contains("Toolkit text"))
    }

    @Test func servicePlansMergeSplitAndCompress() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let a = d.appendingPathComponent("a.pdf"), b = d.appendingPathComponent("b.pdf")
        let png = d.appendingPathComponent("c.png")
        makePDF(at: a, pages: 2); makePDF(at: b, pages: 3)
        makePNG(at: png, width: 40, height: 30, noisy: false)
        let service = ConversionService()

        let merge = try await service.makePlan(
            urls: [a, b, png], targets: TargetRecipe(image: .pdf), suffix: "", pdfMode: .merge
        )
        let item = try #require(merge.items.first)
        #expect(merge.items.count == 1)
        #expect(item.mergeSources == [a, b, png])
        let merged = try await service.convert(item, options: ConversionOptions(
            target: .pdf, quality: 0.8, suffix: "", preserveMetadata: false
        ))
        #expect(PDFDocument(url: merged.url)?.pageCount == 6)

        let split = try await service.makePlan(
            urls: [b], targets: TargetRecipe(), suffix: "", pdfMode: .split
        )
        #expect(split.items.map(\.outputName) == ["b-page-01.pdf", "b-page-02.pdf", "b-page-03.pdf"])
        let page = try await service.convert(split.items[1], options: ConversionOptions(
            target: .pdf, quality: 0.8, suffix: "", preserveMetadata: false
        ))
        #expect(PDFDocument(url: page.url)?.pageCount == 1)

        let compress = try await service.makePlan(
            urls: [a], targets: TargetRecipe(), suffix: "-small", pdfMode: .compress
        )
        #expect(compress.items.map(\.outputName) == ["a-small.pdf"])
        #expect(compress.items.first?.pdfMode == .compress)
    }
}
