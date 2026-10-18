import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import FileFormatterCore

@Suite("PDF pages")
struct PDFPageTests {
    @Test func plansAndConvertsEveryPDFPage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterPDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdf = directory.appendingPathComponent("two-pages.pdf")
        try makeTwoPagePDF(at: pdf)

        let service = ConversionService()
        let plan = try await service.makePlan(
            urls: [pdf],
            targets: TargetRecipe(image: .png, data: .json),
            suffix: ""
        )

        #expect(plan.items.count == 2)
        #expect(plan.items[0].pageIndex == 1)
        #expect(plan.items[1].pageIndex == 2)
        #expect(plan.items[0].outputName == "two-pages-page-01.png")
        #expect(plan.items[1].outputName == "two-pages-page-02.png")
        #expect(plan.items.allSatisfy { $0.fidelity == .extract })

        for item in plan.items {
            let result = try await service.convert(
                item,
                options: ConversionOptions(
                    target: .png,
                    quality: 1,
                    suffix: "",
                    preserveMetadata: false
                )
            )
            #expect(FileManager.default.fileExists(atPath: result.url.path))
            #expect(result.outputBytes > 0)
            let source = CGImageSourceCreateWithURL(result.url as CFURL, nil)
            let type = source.flatMap { CGImageSourceGetType($0) as String? }
            #expect(type == UTType.png.identifier)
        }
    }

    private func makeTwoPagePDF(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 120, height: 90)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.writeFailed("Could not create a PDF context.")
        }
        for page in 1...2 {
            context.beginPDFPage(nil)
            context.setFillColor(
                page == 1
                    ? CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
                    : CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
            )
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
