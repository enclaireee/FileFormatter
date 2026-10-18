import AppKit
import CoreGraphics
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
