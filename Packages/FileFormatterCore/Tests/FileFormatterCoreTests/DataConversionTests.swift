import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FileFormatterCore

@Suite("Mixed and data conversion")
struct DataConversionTests {
    @Test func plansMixedBatchAndConvertsCSVToJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterData-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = directory.appendingPathComponent("fixture.png")
        try makePNG(at: image)
        let table = directory.appendingPathComponent("people.csv")
        try "name,role\nAda,engineer\nGrace,admiral\n".write(to: table, atomically: true, encoding: .utf8)

        let service = ConversionService()
        let plan = try await service.makePlan(
            urls: [image, table],
            targets: TargetRecipe(image: .webp, data: .json),
            suffix: "-out"
        )

        #expect(plan.items.count == 2)
        let imageItem = try #require(plan.items.first)
        let dataItem = try #require(plan.items.last)
        #expect(imageItem.outputName == "fixture-out.webp")
        #expect(imageItem.fidelity == .lossy)
        #expect(dataItem.outputName == "people-out.json")
        #expect(dataItem.kind == .data)
        #expect(dataItem.fidelity == .reencode)

        let result = try await service.convert(
            dataItem,
            options: ConversionOptions(
                target: .json,
                quality: 1,
                suffix: "-out",
                preserveMetadata: true
            )
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.url))
        let rows = try #require(json as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["name"] as? String == "Ada")
    }

    @Test func convertsCSVToXLSXAndBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterXLSX-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let table = directory.appendingPathComponent("people.csv")
        let csv = ["name,role", "Ada,engineer", "Grace,admiral", ""].joined(separator: "\n")
        try csv.write(to: table, atomically: true, encoding: .utf8)

        let service = ConversionService()
        let xlsxPlan = try await service.makePlan(urls: [table], target: .xlsx, suffix: "-book")
        let xlsxItem = try #require(xlsxPlan.items.first)
        #expect(xlsxItem.outputName == "people-book.xlsx")
        let xlsxResult = try await service.convert(
            xlsxItem,
            options: ConversionOptions(target: .xlsx, quality: 1, suffix: "-book", preserveMetadata: false)
        )
        let bytes = try Data(contentsOf: xlsxResult.url)
        #expect(bytes.starts(with: [0x50, 0x4B]))

        let csvPlan = try await service.makePlan(urls: [xlsxResult.url], target: .csv, suffix: "-table")
        let csvItem = try #require(csvPlan.items.first)
        let csvResult = try await service.convert(
            csvItem,
            options: ConversionOptions(target: .csv, quality: 1, suffix: "-table", preserveMetadata: false)
        )
        let text = try String(contentsOf: csvResult.url, encoding: .utf8)
        #expect(text.contains("name,role"))
        #expect(text.contains("Ada,engineer"))
    }

    private func makePNG(at url: URL) throws {
        let width = 8
        let height = 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = {
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }(), let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.writeFailed("Could not create the PNG fixture.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.writeFailed("Could not write the PNG fixture.")
        }
    }
}
