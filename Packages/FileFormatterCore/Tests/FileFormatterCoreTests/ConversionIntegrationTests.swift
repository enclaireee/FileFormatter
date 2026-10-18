import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FileFormatterCore

@Suite("Conversion pipeline")
struct ConversionIntegrationTests {
    @Test func plansAndConvertsPNGToJPEG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("fixture.png")
        try makePNG(at: source)

        let service = ConversionService()
        let plan = try await service.makePlan(
            urls: [source],
            target: .jpeg,
            suffix: "-converted"
        )

        #expect(plan.items.count == 1)
        let item = try #require(plan.items.first)
        #expect(item.fidelity == .lossy)
        #expect(item.outputName == "fixture-converted.jpg")

        let result = try await service.convert(
            item,
            options: ConversionOptions(
                target: .jpeg,
                quality: 0.8,
                suffix: "-converted",
                preserveMetadata: true
            )
        )

        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(result.outputBytes > 0)

        let outputSource = CGImageSourceCreateWithURL(result.url as CFURL, nil)
        let type = outputSource.flatMap { CGImageSourceGetType($0) as String? }
        #expect(type == UTType.jpeg.identifier)
    }

    @Test func convertsPNGToEveryImageTarget() async throws {
        for target in ConversionTarget.allCases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileFormatterTargets-\(target.rawValue)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let source = directory.appendingPathComponent("fixture.png")
            try makePNG(at: source)

            let service = ConversionService()
            let plan = try await service.makePlan(urls: [source], target: target, suffix: "-out")
            let item = try #require(plan.items.first, "missing plan for \(target)")

            let result = try await service.convert(
                item,
                options: ConversionOptions(
                    target: target,
                    quality: 0.85,
                    suffix: "-out",
                    preserveMetadata: true
                )
            )
            #expect(FileManager.default.fileExists(atPath: result.url.path), "\(target) output missing")
            #expect(result.outputBytes > 0, "\(target) output empty")
        }
    }

    private func makePNG(at url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 32,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.writeFailed("Could not create a test bitmap.")
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw ConversionError.writeFailed("Could not create a test PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.writeFailed("Could not write a test PNG.")
        }
    }
}
